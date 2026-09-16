import Foundation
import NetworkExtension
import FaradayCore
import Synchronization

final class FilterEngine: Sendable {
    static let shared = FilterEngine()

    enum NewFlowAction {
        case allow
        case drop
        case watch
    }

    enum DataAction {
        case keepWatching
        case stopWatching
        case drop
    }

    private struct WatchedFlow: @unchecked Sendable {
        let flow: NEFilterSocketFlow
        let udid: SimulatorUDID
        var inboundFinished = false
        var outboundFinished = false
    }

    private struct State {
        var policy: NetworkPolicy
        var watchedFlows: [UUID: WatchedFlow] = [:]
        var droppedFlows: [SimulatorUDID: Int] = [:]
        var unidentifiedSimulatorFlows = 0
    }

    private final class ProviderReference: @unchecked Sendable {
        weak var provider: FilterDataProvider?
    }

    private static let maxWatchedFlows = 20_000

    let resolver = SimulatorResolver()
    private let persistence = PolicyPersistence()
    private let state: Mutex<State>
    private let providerReference = Mutex(ProviderReference())
    private let startedAt = Date()
    private let log = Log.logger("engine")

    private init() {
        state = Mutex(State(policy: persistence.load()))
    }

    // MARK: Provider lifecycle

    func attach(_ provider: FilterDataProvider) {
        providerReference.withLock { $0.provider = provider }
    }

    func detach(_ provider: FilterDataProvider) {
        providerReference.withLock { reference in
            if reference.provider === provider {
                reference.provider = nil
            }
        }
        state.withLock { $0.watchedFlows.removeAll() }
    }

    // MARK: Flow decisions

    func newFlowAction(for flow: NEFilterSocketFlow, origin: FlowOrigin) -> NewFlowAction {
        if origin == .host {
            return .allow
        }
        let watched = WatchedFlow(flow: flow, udid: origin.udid ?? Self.unknownDevice)
        return state.withLock { state in
            if origin == .unidentifiedSimulator {
                state.unidentifiedSimulatorFlows += 1
            }
            if state.policy.decision(for: origin) == .drop {
                state.droppedFlows[watched.udid, default: 0] += 1
                return .drop
            }
            guard state.policy.killExistingConnections, origin.udid != nil else {
                return .allow
            }
            if state.watchedFlows.count >= Self.maxWatchedFlows {
                state.watchedFlows.removeAll()
            }
            state.watchedFlows[flow.identifier] = watched
            return .watch
        }
    }

    func dataAction(for flow: NEFilterFlow) -> DataAction {
        state.withLock { state in
            guard let watched = state.watchedFlows[flow.identifier] else { return .stopWatching }
            guard state.policy.offlineSimulators.contains(watched.udid) else { return .keepWatching }
            state.watchedFlows[flow.identifier] = nil
            state.droppedFlows[watched.udid, default: 0] += 1
            return .drop
        }
    }

    func flowFinished(_ flow: NEFilterFlow, direction: NETrafficDirection) {
        state.withLock { state in
            guard var watched = state.watchedFlows[flow.identifier] else { return }
            if direction == .inbound { watched.inboundFinished = true } else { watched.outboundFinished = true }
            state.watchedFlows[flow.identifier] = watched.inboundFinished && watched.outboundFinished ? nil : watched
        }
    }

    // MARK: Control

    func setOffline(_ offline: Bool, udid: SimulatorUDID) {
        let (policy, flowsToCut) = state.withLock { state -> (NetworkPolicy, [WatchedFlow]) in
            if offline {
                state.policy.offlineSimulators.insert(udid)
            } else {
                state.policy.offlineSimulators.remove(udid)
            }
            guard offline, state.policy.killExistingConnections else { return (state.policy, []) }
            let flows = state.watchedFlows.filter { $0.value.udid == udid }
            for id in flows.keys {
                state.watchedFlows[id] = nil
            }
            state.droppedFlows[udid, default: 0] += flows.count
            return (state.policy, Array(flows.values))
        }
        persistence.save(policy)
        log.info("Simulator \(udid.rawValue, privacy: .public) is now \(offline ? "offline" : "online", privacy: .public); cutting \(flowsToCut.count) open flows")
        cut(flowsToCut)
    }

    func setAllOnline() {
        let policy = state.withLock { state in
            state.policy.offlineSimulators.removeAll()
            return state.policy
        }
        persistence.save(policy)
        log.info("All simulators are online")
    }

    func setBootedSimulators(_ udids: Set<SimulatorUDID>) {
        let policy = state.withLock { state in
            state.policy.bootedSimulators = udids
            return state.policy
        }
        persistence.save(policy)
    }

    func setKillExistingConnections(_ enabled: Bool) {
        let policy = state.withLock { state in
            state.policy.killExistingConnections = enabled
            if !enabled {
                state.watchedFlows.removeAll()
            }
            return state.policy
        }
        persistence.save(policy)
    }

    func status() -> FilterStatus {
        let bundle = Bundle.main
        let version = "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
        return state.withLock { state in
            FilterStatus(
                policy: state.policy,
                extensionVersion: version,
                startedAt: startedAt,
                droppedFlows: Dictionary(uniqueKeysWithValues: state.droppedFlows.map { ($0.key.rawValue, $0.value) }),
                trackedFlows: Dictionary(grouping: state.watchedFlows.values, by: \.udid.rawValue).mapValues(\.count),
                unidentifiedSimulatorFlows: state.unidentifiedSimulatorFlows,
                isFilterRunning: providerReference.withLock { $0.provider != nil }
            )
        }
    }

    private func cut(_ flows: [WatchedFlow]) {
        guard !flows.isEmpty, let provider = providerReference.withLock({ $0.provider }) else { return }
        for watched in flows {
            provider.update(watched.flow, using: .drop(), for: .any)
        }
    }

    private static let unknownDevice = SimulatorUDID("00000000-0000-0000-0000-000000000000")!
}

private extension FlowOrigin {
    var udid: SimulatorUDID? {
        if case .simulator(let udid) = self { udid } else { nil }
    }
}
