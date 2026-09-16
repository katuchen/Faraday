import Foundation

public struct NetworkPolicy: Codable, Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case allow
        case drop
    }

    public var offlineSimulators: Set<SimulatorUDID>
    public var bootedSimulators: Set<SimulatorUDID>
    public var killExistingConnections: Bool

    public init(
        offlineSimulators: Set<SimulatorUDID> = [],
        bootedSimulators: Set<SimulatorUDID> = [],
        killExistingConnections: Bool = true
    ) {
        self.offlineSimulators = offlineSimulators
        self.bootedSimulators = bootedSimulators
        self.killExistingConnections = killExistingConnections
    }

    public func decision(for origin: FlowOrigin) -> Decision {
        switch origin {
        case .host:
            return .allow
        case .simulator(let udid):
            return offlineSimulators.contains(udid) ? .drop : .allow
        case .unidentifiedSimulator:
            guard !offlineSimulators.isEmpty, !bootedSimulators.isEmpty else { return .allow }
            return bootedSimulators.isSubset(of: offlineSimulators) ? .drop : .allow
        }
    }
}
