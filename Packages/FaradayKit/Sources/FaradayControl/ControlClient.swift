import Foundation
import FaradayCore
import Synchronization

public enum ControlClientError: Error, LocalizedError {
    case missingConfiguration(String)
    case connection(String)
    case remote(String)
    case invalidReply

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            "Missing \(key) in Info.plist."
        case .connection(let message):
            "Can't reach the Faraday filter extension (\(message)). Is it installed and enabled?"
        case .remote(let message):
            message
        case .invalidReply:
            "The filter extension sent an unexpected reply."
        }
    }
}

public final class ControlClient: @unchecked Sendable {
    private let machServiceName: String
    private let serverRequirement: String?
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(machServiceName: String, serverRequirement: String?) {
        self.machServiceName = machServiceName
        self.serverRequirement = serverRequirement
    }

    public convenience init(bundle: Bundle = .main) throws {
        guard let machServiceName = bundle.object(forInfoDictionaryKey: FaradayInfoKey.machServiceName) as? String,
              !machServiceName.isEmpty
        else {
            throw ControlClientError.missingConfiguration(FaradayInfoKey.machServiceName)
        }
        let filterIdentifier = bundle.object(forInfoDictionaryKey: FaradayInfoKey.filterBundleIdentifier) as? String
        let team = bundle.object(forInfoDictionaryKey: FaradayInfoKey.teamIdentifier) as? String
        var requirement: String?
        if let filterIdentifier, let team, !team.isEmpty {
            requirement = "identifier \"\(filterIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        self.init(machServiceName: machServiceName, serverRequirement: requirement)
    }

    deinit {
        connection?.invalidate()
    }

    public func status() async throws -> FilterStatus {
        let data: Data = try await call { proxy, complete in
            proxy.fetchStatus { data, error in
                if let error {
                    complete(.failure(ControlClientError.remote(error)))
                } else if let data {
                    complete(.success(data))
                } else {
                    complete(.failure(ControlClientError.invalidReply))
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FilterStatus.self, from: data)
    }

    public func setOffline(_ offline: Bool, udid: SimulatorUDID) async throws {
        try await callVoid { proxy, reply in proxy.setOffline(offline, udid: udid.rawValue, reply: reply) }
    }

    public func setAllOnline() async throws {
        try await callVoid { proxy, reply in proxy.setAllOnline(reply: reply) }
    }

    public func setBootedSimulators(_ udids: [SimulatorUDID]) async throws {
        try await callVoid { proxy, reply in proxy.setBootedSimulators(udids.map(\.rawValue), reply: reply) }
    }

    public func setKillExistingConnections(_ enabled: Bool) async throws {
        try await callVoid { proxy, reply in proxy.setKillExistingConnections(enabled, reply: reply) }
    }

    private func callVoid(
        _ send: @escaping (FaradayControlProtocol, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        let _: Bool = try await call { proxy, complete in
            send(proxy) { error in
                complete(error.map { .failure(ControlClientError.remote($0)) } ?? .success(true))
            }
        }
    }

    private func call<Value: Sendable>(
        _ send: @escaping (FaradayControlProtocol, @escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<Value, any Error>?>(continuation)
            let complete: @Sendable (Result<Value, any Error>) -> Void = { result in
                pending.withLock { $0.take() }?.resume(with: result)
            }
            let remote = currentConnection().remoteObjectProxyWithErrorHandler { error in
                complete(.failure(ControlClientError.connection(error.localizedDescription)))
            }
            guard let proxy = remote as? FaradayControlProtocol else {
                complete(.failure(ControlClientError.invalidReply))
                return
            }
            send(proxy, complete)
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return connection
        }
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = ControlInterface.make()
        if let serverRequirement {
            connection.setCodeSigningRequirement(serverRequirement)
        }
        let reset: @Sendable () -> Void = { [weak self] in self?.dropConnection() }
        connection.invalidationHandler = reset
        connection.interruptionHandler = reset
        connection.resume()
        self.connection = connection
        return connection
    }

    private func dropConnection() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }
}
