import Foundation
import Network

extension NWPath {
    public var faraday_status: NWPath.Status {
        faraday_shim_is_offline() ? .unsatisfied : status
    }
}

extension NWPathMonitor {
    public var faraday_pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { pathUpdateHandler }
        set {
            guard let handler = newValue else {
                MonitorRegistry.shared.remove(self)
                pathUpdateHandler = nil
                return
            }
            MonitorRegistry.shared.register(self, handler: handler)
            pathUpdateHandler = { [weak self] path in
                if let self {
                    MonitorRegistry.shared.record(path, for: self)
                }
                handler(path)
            }
        }
    }
}

final class MonitorRegistry: @unchecked Sendable {
    static let shared = MonitorRegistry()

    private struct Entry {
        weak var monitor: NWPathMonitor?
        let handler: @Sendable (NWPath) -> Void
        var lastPath: NWPath?
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ monitor: NWPathMonitor, handler: @escaping @Sendable (NWPath) -> Void) {
        lock.withLock {
            entries[ObjectIdentifier(monitor)] = Entry(monitor: monitor, handler: handler, lastPath: nil)
        }
    }

    func remove(_ monitor: NWPathMonitor) {
        lock.withLock {
            _ = entries.removeValue(forKey: ObjectIdentifier(monitor))
        }
    }

    func record(_ path: NWPath, for monitor: NWPathMonitor) {
        lock.withLock {
            entries[ObjectIdentifier(monitor)]?.lastPath = path
        }
    }

    func redeliverLastPaths() {
        let deliveries = lock.withLock { () -> [(DispatchQueue, @Sendable (NWPath) -> Void, NWPath)] in
            entries = entries.filter { $0.value.monitor != nil }
            return entries.values.compactMap { entry in
                guard let monitor = entry.monitor, let path = entry.lastPath else { return nil }
                return (monitor.queue ?? .main, entry.handler, path)
            }
        }
        for (queue, handler, path) in deliveries {
            queue.async { handler(path) }
        }
    }
}

@_cdecl("faraday_swift_state_did_change")
public func faradaySwiftStateDidChange() {
    MonitorRegistry.shared.redeliverLastPaths()
}
