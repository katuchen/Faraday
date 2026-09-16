import Foundation

@objc(FaradayControlProtocol)
public protocol FaradayControlProtocol {
    func fetchStatus(reply: @escaping @Sendable (Data?, String?) -> Void)
    func setOffline(_ offline: Bool, udid: String, reply: @escaping @Sendable (String?) -> Void)
    func setAllOnline(reply: @escaping @Sendable (String?) -> Void)
    func setBootedSimulators(_ udids: [String], reply: @escaping @Sendable (String?) -> Void)
    func setKillExistingConnections(_ enabled: Bool, reply: @escaping @Sendable (String?) -> Void)
}

public enum ControlInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FaradayControlProtocol.self)
        let stringArray = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(
            stringArray,
            for: #selector(FaradayControlProtocol.setBootedSimulators(_:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }
}

public enum FaradayInfoKey {
    public static let machServiceName = "FaradayMachServiceName"
    public static let filterBundleIdentifier = "FaradayFilterBundleIdentifier"
    public static let appBundleIdentifier = "FaradayAppBundleIdentifier"
    public static let cliIdentifier = "FaradayCLIIdentifier"
    public static let teamIdentifier = "FaradayTeamIdentifier"
}

public struct FilterStatus: Codable, Sendable, Equatable {
    public var policy: NetworkPolicy
    public var extensionVersion: String
    public var startedAt: Date
    public var droppedFlows: [String: Int]
    public var trackedFlows: [String: Int]
    public var unidentifiedSimulatorFlows: Int
    public var isFilterRunning: Bool

    public init(
        policy: NetworkPolicy,
        extensionVersion: String,
        startedAt: Date,
        droppedFlows: [String: Int] = [:],
        trackedFlows: [String: Int] = [:],
        unidentifiedSimulatorFlows: Int = 0,
        isFilterRunning: Bool = false
    ) {
        self.policy = policy
        self.extensionVersion = extensionVersion
        self.startedAt = startedAt
        self.droppedFlows = droppedFlows
        self.trackedFlows = trackedFlows
        self.unidentifiedSimulatorFlows = unidentifiedSimulatorFlows
        self.isFilterRunning = isFilterRunning
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(NetworkPolicy.self, forKey: .policy)
        extensionVersion = try container.decode(String.self, forKey: .extensionVersion)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        droppedFlows = try container.decodeIfPresent([String: Int].self, forKey: .droppedFlows) ?? [:]
        trackedFlows = try container.decodeIfPresent([String: Int].self, forKey: .trackedFlows) ?? [:]
        unidentifiedSimulatorFlows = try container.decodeIfPresent(Int.self, forKey: .unidentifiedSimulatorFlows) ?? 0
        isFilterRunning = try container.decodeIfPresent(Bool.self, forKey: .isFilterRunning) ?? false
    }
}
