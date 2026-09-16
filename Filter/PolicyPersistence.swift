import Foundation
import FaradayCore

struct PolicyPersistence: Sendable {
    private static let policyKey = "policy"
    private static let bootSessionKey = "bootSession"
    private static let killExistingKey = "killExistingConnections"

    private var defaults: UserDefaults { .standard }

    func load() -> NetworkPolicy {
        var policy = NetworkPolicy()
        if defaults.object(forKey: Self.killExistingKey) != nil {
            policy.killExistingConnections = defaults.bool(forKey: Self.killExistingKey)
        }
        guard let bootSession = BootSession.identifier,
              defaults.string(forKey: Self.bootSessionKey) == bootSession,
              let data = defaults.data(forKey: Self.policyKey),
              let saved = try? JSONDecoder().decode(NetworkPolicy.self, from: data)
        else {
            return policy
        }
        policy.offlineSimulators = saved.offlineSimulators
        policy.bootedSimulators = saved.bootedSimulators
        return policy
    }

    func save(_ policy: NetworkPolicy) {
        defaults.set(policy.killExistingConnections, forKey: Self.killExistingKey)
        defaults.set(BootSession.identifier, forKey: Self.bootSessionKey)
        defaults.set(try? JSONEncoder().encode(policy), forKey: Self.policyKey)
    }
}
