#include "CFaradaySupport.h"

#include <bsm/libbsm.h>
#include <errno.h>
#include <libproc.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>

static int copy_audit_token(const uint8_t *bytes, size_t length, audit_token_t *token) {
    if (bytes == NULL || length != sizeof(audit_token_t)) {
        return 0;
    }
    memcpy(token, bytes, sizeof(audit_token_t));
    return 1;
}

pid_t faraday_audit_token_pid(const uint8_t *bytes, size_t length) {
    audit_token_t token;
    return copy_audit_token(bytes, length, &token) ? audit_token_to_pid(token) : -1;
}

int faraday_audit_token_pidversion(const uint8_t *bytes, size_t length) {
    audit_token_t token;
    return copy_audit_token(bytes, length, &token) ? audit_token_to_pidversion(token) : -1;
}

int faraday_proc_path(pid_t pid, char *buffer, uint32_t buffer_size) {
    int length = proc_pidpath(pid, buffer, buffer_size);
    return length > 0 ? length : 0;
}

pid_t faraday_proc_parent(pid_t pid) {
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, PROC_PIDTBSDINFO_SIZE);
    return size == PROC_PIDTBSDINFO_SIZE ? (pid_t)info.pbi_ppid : -1;
}

int faraday_proc_args(pid_t pid, char *buffer, size_t *size) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    return sysctl(mib, 3, buffer, size, NULL, 0) == 0 ? 0 : errno;
}

size_t faraday_arg_max(void) {
    int mib[2] = {CTL_KERN, KERN_ARGMAX};
    int value = 0;
    size_t size = sizeof(value);
    return sysctl(mib, 2, &value, &size, NULL, 0) == 0 && value > 0 ? (size_t)value : 0;
}

int faraday_boot_session_uuid(char *buffer, size_t buffer_size) {
    size_t size = buffer_size;
    return sysctlbyname("kern.bootsessionuuid", buffer, &size, NULL, 0) == 0 ? 0 : errno;
}

int faraday_list_pids(pid_t *pids, int capacity) {
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    return count > 0 ? count : 0;
}
