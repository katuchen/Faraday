#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <mach-o/dyld.h>
#import <netdb.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>
#import <sys/stat.h>

#import "FaradayShim.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

extern void faraday_swift_state_did_change(void);

static const char *const kStateChangedNotification = "com.faraday.state-changed";

static os_log_t shim_log;
static bool shim_active;
static char *shim_state_file;
static atomic_bool shim_offline;
static dispatch_queue_t shim_queue;
static dispatch_source_t shim_poll_timer;

bool faraday_shim_is_offline(void) {
    return shim_active && atomic_load(&shim_offline);
}

#pragma mark - Registries

@interface FDPathMonitorRecord : NSObject
@property (nonatomic, strong) nw_path_monitor_t monitor;
@property (nonatomic, copy) nw_path_monitor_update_handler_t handler;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) nw_path_t lastPath;
@end

@implementation FDPathMonitorRecord
@end

@interface FDReachabilityRecord : NSObject
@property (nonatomic) SCNetworkReachabilityRef target;
@property (nonatomic) SCNetworkReachabilityCallBack callout;
@property (nonatomic) SCNetworkReachabilityContext context;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic) CFRunLoopRef runLoop;
@property (nonatomic, copy) NSString *runLoopMode;
@property (atomic) SCNetworkReachabilityFlags lastFlags;
@property (atomic) BOOL hasLastFlags;
@end

@implementation FDReachabilityRecord

- (void)setInfoFromContext:(SCNetworkReachabilityContext *)context {
    SCNetworkReachabilityContext old = _context;
    SCNetworkReachabilityContext copied = context ? *context : (SCNetworkReachabilityContext){0};
    if (copied.retain != NULL && copied.info != NULL) {
        copied.info = (void *)copied.retain(copied.info);
    }
    _context = copied;
    if (old.release != NULL && old.info != NULL) {
        old.release(old.info);
    }
}

- (void)dealloc {
    [self setInfoFromContext:NULL];
    if (_runLoop != NULL) {
        CFRelease(_runLoop);
    }
    if (_target != NULL) {
        CFRelease(_target);
    }
}

@end

static os_unfair_lock registry_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSValue *, FDPathMonitorRecord *> *path_monitors;
static NSMutableDictionary<NSValue *, FDReachabilityRecord *> *reachability_targets;

static NSValue *key_for(void *pointer) {
    return [NSValue valueWithPointer:pointer];
}

static FDPathMonitorRecord *path_monitor_record(nw_path_monitor_t monitor) {
    os_unfair_lock_lock(&registry_lock);
    NSValue *key = key_for((__bridge void *)monitor);
    FDPathMonitorRecord *record = path_monitors[key];
    if (record == nil) {
        record = [FDPathMonitorRecord new];
        record.monitor = monitor;
        path_monitors[key] = record;
    }
    os_unfair_lock_unlock(&registry_lock);
    return record;
}

static FDReachabilityRecord *reachability_record(SCNetworkReachabilityRef target, bool create) {
    os_unfair_lock_lock(&registry_lock);
    NSValue *key = key_for((void *)target);
    FDReachabilityRecord *record = reachability_targets[key];
    if (record == nil && create) {
        record = [FDReachabilityRecord new];
        record.target = (SCNetworkReachabilityRef)CFRetain(target);
        reachability_targets[key] = record;
    }
    os_unfair_lock_unlock(&registry_lock);
    return record;
}

#pragma mark - Network.framework C API

static nw_path_status_t fd_nw_path_get_status(nw_path_t path) {
    return faraday_shim_is_offline() ? nw_path_status_unsatisfied : nw_path_get_status(path);
}

static void fd_nw_path_monitor_set_update_handler(nw_path_monitor_t monitor, nw_path_monitor_update_handler_t handler) {
    if (!shim_active || handler == nil) {
        nw_path_monitor_set_update_handler(monitor, handler);
        return;
    }
    FDPathMonitorRecord *record = path_monitor_record(monitor);
    record.handler = handler;
    __weak FDPathMonitorRecord *weakRecord = record;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        weakRecord.lastPath = path;
        handler(path);
    });
}

static void fd_nw_path_monitor_set_queue(nw_path_monitor_t monitor, dispatch_queue_t queue) {
    if (shim_active) {
        path_monitor_record(monitor).queue = queue;
    }
    nw_path_monitor_set_queue(monitor, queue);
}

static void fd_nw_path_monitor_cancel(nw_path_monitor_t monitor) {
    if (shim_active) {
        os_unfair_lock_lock(&registry_lock);
        [path_monitors removeObjectForKey:key_for((__bridge void *)monitor)];
        os_unfair_lock_unlock(&registry_lock);
    }
    nw_path_monitor_cancel(monitor);
}

#pragma mark - SCNetworkReachability

static void fd_reachability_trampoline(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    FDReachabilityRecord *record = reachability_record(target, false);
    if (record == nil) {
        return;
    }
    record.lastFlags = flags;
    record.hasLastFlags = YES;
    if (record.callout != NULL) {
        record.callout(target, faraday_shim_is_offline() ? 0 : flags, record.context.info);
    }
}

static Boolean fd_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    if (faraday_shim_is_offline()) {
        *flags = 0;
        return true;
    }
    return SCNetworkReachabilityGetFlags(target, flags);
}

static Boolean fd_SCNetworkReachabilitySetCallback(SCNetworkReachabilityRef target,
                                                   SCNetworkReachabilityCallBack callout,
                                                   SCNetworkReachabilityContext *context) {
    if (!shim_active) {
        return SCNetworkReachabilitySetCallback(target, callout, context);
    }
    if (callout == NULL) {
        os_unfair_lock_lock(&registry_lock);
        [reachability_targets removeObjectForKey:key_for((void *)target)];
        os_unfair_lock_unlock(&registry_lock);
        return SCNetworkReachabilitySetCallback(target, NULL, NULL);
    }
    FDReachabilityRecord *record = reachability_record(target, true);
    record.callout = callout;
    [record setInfoFromContext:context];
    return SCNetworkReachabilitySetCallback(target, fd_reachability_trampoline, NULL);
}

static Boolean fd_SCNetworkReachabilitySetDispatchQueue(SCNetworkReachabilityRef target, dispatch_queue_t queue) {
    if (shim_active) {
        reachability_record(target, true).queue = queue;
    }
    return SCNetworkReachabilitySetDispatchQueue(target, queue);
}

static Boolean fd_SCNetworkReachabilityScheduleWithRunLoop(SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef mode) {
    if (shim_active && runLoop != NULL) {
        FDReachabilityRecord *record = reachability_record(target, true);
        if (record.runLoop != NULL) {
            CFRelease(record.runLoop);
        }
        record.runLoop = (CFRunLoopRef)CFRetain(runLoop);
        record.runLoopMode = (__bridge NSString *)mode;
    }
    return SCNetworkReachabilityScheduleWithRunLoop(target, runLoop, mode);
}

#pragma mark - DNS

static bool is_loopback_name(const char *node) {
    size_t length = strlen(node);
    while (length > 0 && node[length - 1] == '.') {
        length--;
    }
    static const char *const localhost = "localhost";
    size_t localhost_length = strlen(localhost);
    if (length < localhost_length || strncasecmp(node + length - localhost_length, localhost, localhost_length) != 0) {
        return false;
    }
    return length == localhost_length || node[length - localhost_length - 1] == '.';
}

static bool is_numeric_address(const char *node) {
    struct in_addr address4;
    if (inet_pton(AF_INET, node, &address4) == 1) {
        return true;
    }
    char without_zone[INET6_ADDRSTRLEN];
    const char *zone = strchr(node, '%');
    if (zone != NULL) {
        size_t length = (size_t)(zone - node);
        if (length >= sizeof(without_zone)) {
            return false;
        }
        memcpy(without_zone, node, length);
        without_zone[length] = '\0';
        node = without_zone;
    }
    struct in6_addr address6;
    return inet_pton(AF_INET6, node, &address6) == 1;
}

static bool dns_lookup_fails(const char *node, int flags) {
    if (!faraday_shim_is_offline() || node == NULL || node[0] == '\0') {
        return false;
    }
    if ((flags & AI_NUMERICHOST) != 0) {
        return false;
    }
    return !is_numeric_address(node) && !is_loopback_name(node);
}

static int fd_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    if (dns_lookup_fails(node, hints != NULL ? hints->ai_flags : 0)) {
        if (result != NULL) {
            *result = NULL;
        }
        return EAI_NONAME;
    }
    return getaddrinfo(node, service, hints, result);
}

static struct hostent *fd_gethostbyname(const char *name) {
    if (dns_lookup_fails(name, 0)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname(name);
}

static struct hostent *fd_gethostbyname2(const char *name, int family) {
    if (dns_lookup_fails(name, 0)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname2(name, family);
}

static struct hostent *fd_getipnodebyname(const char *name, int family, int flags, int *error) {
    if (dns_lookup_fails(name, flags)) {
        if (error != NULL) {
            *error = HOST_NOT_FOUND;
        }
        return NULL;
    }
    return getipnodebyname(name, family, flags, error);
}

#pragma mark - State changes

static void redeliver_to_observers(bool offline) {
    os_unfair_lock_lock(&registry_lock);
    NSArray<FDPathMonitorRecord *> *monitors = path_monitors.allValues;
    NSArray<FDReachabilityRecord *> *targets = reachability_targets.allValues;
    os_unfair_lock_unlock(&registry_lock);

    for (FDPathMonitorRecord *record in monitors) {
        nw_path_monitor_update_handler_t handler = record.handler;
        nw_path_t path = record.lastPath;
        if (handler != nil && path != nil) {
            dispatch_async(record.queue ?: dispatch_get_main_queue(), ^{
                handler(path);
            });
        }
    }

    for (FDReachabilityRecord *record in targets) {
        if (record.callout == NULL || (record.queue == nil && record.runLoop == NULL)) {
            continue;
        }
        dispatch_async(shim_queue, ^{
            SCNetworkReachabilityFlags flags = 0;
            if (!offline) {
                if (record.hasLastFlags) {
                    flags = record.lastFlags;
                } else {
                    SCNetworkReachabilityGetFlags(record.target, &flags);
                }
            }
            void (^deliver)(void) = ^{
                record.callout(record.target, flags, record.context.info);
            };
            if (record.queue != nil) {
                dispatch_async(record.queue, deliver);
            } else {
                CFRunLoopPerformBlock(record.runLoop, (__bridge CFStringRef)record.runLoopMode, deliver);
                CFRunLoopWakeUp(record.runLoop);
            }
        });
    }

    faraday_swift_state_did_change();
}

static void reload_state(void) {
    struct stat info;
    bool offline = stat(shim_state_file, &info) == 0;
    bool previous = atomic_exchange(&shim_offline, offline);
    if (offline != previous) {
        os_log(shim_log, "Network is now %{public}s", offline ? "offline" : "online");
        redeliver_to_observers(offline);
    }
}

static char *copy_state_file_path(void) {
    const char *explicit_file = getenv("FARADAY_STATE_FILE");
    if (explicit_file != NULL && explicit_file[0] != '\0') {
        return strdup(explicit_file);
    }
    const char *udid = getenv("SIMULATOR_UDID");
    if (udid == NULL || udid[0] == '\0') {
        return NULL;
    }
    NSString *directory;
    const char *explicit_directory = getenv("FARADAY_STATE_DIR");
    const char *host_home = getenv("SIMULATOR_HOST_HOME");
    if (explicit_directory != NULL && explicit_directory[0] != '\0') {
        directory = @(explicit_directory);
    } else if (host_home != NULL && host_home[0] != '\0') {
        directory = [@(host_home) stringByAppendingPathComponent:@"Library/Application Support/Faraday/State"];
    } else {
        return NULL;
    }
    NSString *file = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.offline", udid]];
    return strdup(file.fileSystemRepresentation);
}

__attribute__((constructor))
static void faraday_shim_initialize(void) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || strstr(executable, "/Containers/Bundle/Application/") == NULL) {
        return;
    }

    char *state_file = copy_state_file_path();
    if (state_file == NULL) {
        return;
    }

    shim_log = os_log_create("Faraday", "shim");
    shim_state_file = state_file;
    path_monitors = [NSMutableDictionary new];
    reachability_targets = [NSMutableDictionary new];
    shim_queue = dispatch_queue_create("com.faraday.shim", DISPATCH_QUEUE_SERIAL);
    struct stat info;
    atomic_store(&shim_offline, stat(shim_state_file, &info) == 0);
    shim_active = true;

    int token = 0;
    notify_register_dispatch(kStateChangedNotification, &token, shim_queue, ^(int t) {
        reload_state();
    });
    shim_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, shim_queue);
    dispatch_source_set_timer(shim_poll_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(shim_poll_timer, ^{
        reload_state();
    });
    dispatch_resume(shim_poll_timer);

    os_log(shim_log, "Active in %{public}s, state file %{public}s, offline: %d", executable, shim_state_file, atomic_load(&shim_offline));
}

#pragma mark - Interpose table

extern void faraday_nwpath_status_getter(void) __asm__("_$s7Network6NWPathV11FaradayShimE14faraday_statusAC6StatusOvg");
extern void network_nwpath_status_getter(void) __asm__("_$s7Network6NWPathV6statusAC6StatusOvg");
extern void faraday_path_update_handler_setter(void) __asm__("_$s7Network13NWPathMonitorC11FaradayShimE25faraday_pathUpdateHandleryAA0B0VYbcSgvs");
extern void network_path_update_handler_setter(void) __asm__("_$s7Network13NWPathMonitorC17pathUpdateHandleryAA0B0VcSgvs");

typedef struct {
    const void *replacement;
    const void *original;
} faraday_interpose_t;

__attribute__((used)) static const faraday_interpose_t faraday_interposes[] __attribute__((section("__DATA,__interpose"))) = {
    {fd_nw_path_get_status, nw_path_get_status},
    {fd_nw_path_monitor_set_update_handler, nw_path_monitor_set_update_handler},
    {fd_nw_path_monitor_set_queue, nw_path_monitor_set_queue},
    {fd_nw_path_monitor_cancel, nw_path_monitor_cancel},
    {fd_SCNetworkReachabilityGetFlags, SCNetworkReachabilityGetFlags},
    {fd_SCNetworkReachabilitySetCallback, SCNetworkReachabilitySetCallback},
    {fd_SCNetworkReachabilitySetDispatchQueue, SCNetworkReachabilitySetDispatchQueue},
    {fd_SCNetworkReachabilityScheduleWithRunLoop, SCNetworkReachabilityScheduleWithRunLoop},
    {fd_getaddrinfo, getaddrinfo},
    {fd_gethostbyname, gethostbyname},
    {fd_gethostbyname2, gethostbyname2},
    {fd_getipnodebyname, getipnodebyname},
    {faraday_nwpath_status_getter, network_nwpath_status_getter},
    {faraday_path_update_handler_setter, network_path_update_handler_setter},
};
