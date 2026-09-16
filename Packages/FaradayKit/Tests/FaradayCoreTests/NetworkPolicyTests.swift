import Foundation
import Testing
@testable import FaradayCore

struct NetworkPolicyTests {
    let a = SimulatorUDID("4AB6C209-AF1B-406A-8371-438B730CB7F5")!
    let b = SimulatorUDID("36DA1BDB-EDE2-40A3-B016-1018008FB749")!

    @Test func hostIsAlwaysAllowed() {
        let policy = NetworkPolicy(offlineSimulators: [a], bootedSimulators: [a])
        #expect(policy.decision(for: .host) == .allow)
    }

    @Test func onlyOfflineSimulatorIsDropped() {
        let policy = NetworkPolicy(offlineSimulators: [a], bootedSimulators: [a, b])
        #expect(policy.decision(for: .simulator(a)) == .drop)
        #expect(policy.decision(for: .simulator(b)) == .allow)
    }

    @Test func unidentifiedSimulatorProcesses() {
        #expect(NetworkPolicy(offlineSimulators: [a], bootedSimulators: [a]).decision(for: .unidentifiedSimulator) == .drop)
        #expect(NetworkPolicy(offlineSimulators: [a], bootedSimulators: [a, b]).decision(for: .unidentifiedSimulator) == .allow)
        #expect(NetworkPolicy(offlineSimulators: [a], bootedSimulators: []).decision(for: .unidentifiedSimulator) == .allow)
        #expect(NetworkPolicy(offlineSimulators: [], bootedSimulators: [a]).decision(for: .unidentifiedSimulator) == .allow)
    }

    @Test func statusRoundTripsThroughJSON() throws {
        let status = FilterStatus(
            policy: NetworkPolicy(offlineSimulators: [a], bootedSimulators: [a, b], killExistingConnections: false),
            extensionVersion: "1.0 (1)",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            droppedFlows: [a.rawValue: 3],
            trackedFlows: [b.rawValue: 2],
            unidentifiedSimulatorFlows: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(FilterStatus.self, from: encoder.encode(status)) == status)
    }
}
