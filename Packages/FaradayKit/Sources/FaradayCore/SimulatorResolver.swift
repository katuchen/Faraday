import Foundation
import Synchronization

public enum FlowOrigin: Hashable, Sendable {
    case host
    case simulator(SimulatorUDID)
    case unidentifiedSimulator
}

public final class SimulatorResolver: Sendable {
    private let inspector: any ProcessInspecting
    private let cacheCapacity: Int
    private let cache = Mutex<[ProcessKey: FlowOrigin]>([:])

    public init(inspector: any ProcessInspecting = LiveProcessInspector(), cacheCapacity: Int = 4096) {
        self.inspector = inspector
        self.cacheCapacity = cacheCapacity
    }

    public func origin(appAuditToken: Data?, processAuditToken: Data?) -> FlowOrigin {
        var sawUnidentifiedSimulator = false
        for token in [appAuditToken, processAuditToken] {
            guard let token, let key = ProcessKey(auditToken: token) else { continue }
            switch origin(of: key, auditToken: token) {
            case .simulator(let udid):
                return .simulator(udid)
            case .unidentifiedSimulator:
                sawUnidentifiedSimulator = true
            case .host:
                break
            }
        }
        return sawUnidentifiedSimulator ? .unidentifiedSimulator : .host
    }

    public func origin(pid: pid_t) -> FlowOrigin {
        origin(of: ProcessKey(pid: pid, version: -1), auditToken: nil)
    }

    public func removeAllCachedOrigins() {
        cache.withLock { $0.removeAll() }
    }

    func origin(of key: ProcessKey, auditToken: Data?) -> FlowOrigin {
        if let cached = cache.withLock({ $0[key] }) {
            return cached
        }
        let (origin, cacheable) = resolve(key, auditToken: auditToken)
        if cacheable, key.version >= 0 {
            cache.withLock { cache in
                if cache.count >= cacheCapacity {
                    cache.removeAll(keepingCapacity: true)
                }
                cache[key] = origin
            }
        }
        return origin
    }

    private func resolve(_ key: ProcessKey, auditToken: Data?) -> (origin: FlowOrigin, cacheable: Bool) {
        let path = auditToken.flatMap(inspector.executablePath(auditToken:)) ?? inspector.executablePath(pid: key.pid)
        var isRuntimeRoot = false
        if let path {
            if let udid = SimulatorMarkers.udid(inPath: path) {
                return (.simulator(udid), true)
            }
            if SimulatorMarkers.isLaunchdSim(executablePath: path) {
                let udid = inspector.arguments(pid: key.pid).flatMap { SimulatorMarkers.udid(inArguments: $0.arguments) }
                return (udid.map(FlowOrigin.simulator) ?? .host, true)
            }
            isRuntimeRoot = SimulatorMarkers.isRuntimeRootPath(path)
            guard isRuntimeRoot || SimulatorMarkers.isCoreSimulatorResourcePath(path) else {
                return (.host, true)
            }
        }

        if let udid = inspector.arguments(pid: key.pid).flatMap({ SimulatorMarkers.udid(inEnvironment: $0.environment) }) {
            return (.simulator(udid), true)
        }
        if let udid = launchdSimAncestorUDID(of: key.pid) {
            return (.simulator(udid), true)
        }
        guard path != nil else { return (.host, false) }
        return (isRuntimeRoot ? .unidentifiedSimulator : .host, true)
    }

    private func launchdSimAncestorUDID(of pid: pid_t) -> SimulatorUDID? {
        var current = pid
        for _ in 0..<8 {
            guard let parent = inspector.parentPID(of: current), parent > 1 else { return nil }
            if let path = inspector.executablePath(pid: parent), SimulatorMarkers.isLaunchdSim(executablePath: path) {
                return inspector.arguments(pid: parent).flatMap { SimulatorMarkers.udid(inArguments: $0.arguments) }
            }
            current = parent
        }
        return nil
    }
}
