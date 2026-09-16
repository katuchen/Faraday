import Foundation
import Observation
import FaradayControl
import FaradayCore

@MainActor
@Observable
final class AppModel {
    private(set) var simulators: [Simulator] = []
    private(set) var offlineSimulators: Set<SimulatorUDID> = []
    private(set) var killExistingConnections = true
    private(set) var isFilterReachable = false
    private(set) var isFilterRunning = false
    var lastError: String?

    var injectsReachabilityShim: Bool {
        didSet {
            UserDefaults.standard.set(injectsReachabilityShim, forKey: "injectsReachabilityShim")
            let inject = injectsReachabilityShim
            let udids = simulators.map(\.udid)
            Task { await applyShimInjection(inject, to: udids) }
        }
    }

    let extensionManager = ExtensionManager()

    @ObservationIgnored private let client = try? ControlClient()
    @ObservationIgnored private let simctl = Simctl()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reportedBootedSimulators: Set<SimulatorUDID>?

    init() {
        injectsReachabilityShim = UserDefaults.standard.bool(forKey: "injectsReachabilityShim")
        extensionManager.refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var anySimulatorOffline: Bool {
        simulators.contains { offlineSimulators.contains($0.udid) }
    }

    var canControlSimulators: Bool {
        extensionManager.state == .ready && client != nil
    }

    var commandLineToolPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/faraday").path
    }

    var xcodeSchemeVariable: String? {
        ReachabilityShim.locateLibrary().map { "DYLD_INSERT_LIBRARIES=\($0.path)" }
    }

    func isOffline(_ simulator: Simulator) -> Bool {
        offlineSimulators.contains(simulator.udid)
    }

    func setOffline(_ offline: Bool, for simulator: Simulator) async {
        guard let client else {
            lastError = "Faraday is missing its XPC configuration."
            return
        }
        do {
            try await client.setBootedSimulators(simulators.map(\.udid))
            try await client.setOffline(offline, udid: simulator.udid)
            if offline {
                offlineSimulators.insert(simulator.udid)
            } else {
                offlineSimulators.remove(simulator.udid)
            }
            lastError = nil
            await updateReachabilityState(offline: offline, udids: [simulator.udid])
            await updateStatusBar(offline: offline, udid: simulator.udid)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAllOnline() async {
        guard let client else { return }
        do {
            let wereOffline = offlineSimulators
            try await client.setAllOnline()
            offlineSimulators = []
            lastError = nil
            await updateReachabilityState(offline: false, udids: Array(wereOffline.union(simulators.map(\.udid))))
            for udid in wereOffline where simulators.contains(where: { $0.udid == udid }) {
                await updateStatusBar(offline: false, udid: udid)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setKillExistingConnections(_ enabled: Bool) async {
        guard let client else { return }
        do {
            try await client.setKillExistingConnections(enabled)
            killExistingConnections = enabled
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        let simctl = self.simctl
        let previous = Set(simulators.map(\.udid))
        if let booted = try? await Task.detached(operation: { try simctl.bootedSimulators() }).value {
            simulators = booted
        }
        let booted = Set(simulators.map(\.udid))
        let newlyBooted = booted.subtracting(previous)
        if injectsReachabilityShim, !newlyBooted.isEmpty {
            await applyShimInjection(true, to: Array(newlyBooted))
        }

        guard let client else {
            isFilterReachable = false
            return
        }
        do {
            let status = try await client.status()
            isFilterReachable = true
            isFilterRunning = status.isFilterRunning
            offlineSimulators = status.policy.offlineSimulators
            killExistingConnections = status.policy.killExistingConnections
            if reportedBootedSimulators != booted {
                try await client.setBootedSimulators(Array(booted))
                reportedBootedSimulators = booted
            }
            let stale = booted.filter { ReachabilityShim.isOffline($0) != offlineSimulators.contains($0) }
            for udid in stale {
                await updateReachabilityState(offline: offlineSimulators.contains(udid), udids: [udid])
            }
            for udid in newlyBooted where offlineSimulators.contains(udid) {
                await updateStatusBar(offline: true, udid: udid)
            }
        } catch {
            isFilterReachable = false
            isFilterRunning = false
            reportedBootedSimulators = nil
        }
        await ensureFilterEnabled()
    }

    private func ensureFilterEnabled() async {
        guard extensionManager.state == .ready else { return }
        await extensionManager.reloadFilterState()
        guard extensionManager.state == .ready, !extensionManager.isFilterEnabled else { return }
        do {
            try await extensionManager.setFilterEnabled(true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateReachabilityState(offline: Bool, udids: [SimulatorUDID]) async {
        let simctl = self.simctl
        let booted = Set(simulators.map(\.udid))
        await Task.detached {
            for udid in udids {
                try? ReachabilityShim.setOffline(offline, udid: udid)
                if booted.contains(udid) {
                    try? simctl.postShimStateChange(udid)
                }
            }
        }.value
    }

    private func applyShimInjection(_ inject: Bool, to udids: [SimulatorUDID]) async {
        guard !udids.isEmpty else { return }
        guard let library = ReachabilityShim.locateLibrary() else {
            lastError = "\(ReachabilityShim.libraryName) is missing from the app bundle."
            return
        }
        let simctl = self.simctl
        let failures = await Task.detached { () -> [String] in
            udids.compactMap { udid in
                do {
                    if inject {
                        try simctl.injectShim(library, into: udid)
                    } else {
                        try simctl.removeShim(from: udid)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }.value
        if let failure = failures.first {
            lastError = failure
        }
    }

    private func updateStatusBar(offline: Bool, udid: SimulatorUDID) async {
        let simctl = self.simctl
        await Task.detached {
            if offline {
                try? simctl.showOfflineStatusBar(udid)
            } else {
                try? simctl.clearStatusBar(udid)
            }
        }.value
    }
}
