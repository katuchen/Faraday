import AppKit
import NetworkExtension
import Observation
import FaradayCore
import SystemExtensions

enum FilterSetupError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Faraday's filter isn't set up yet."
        }
    }
}

@MainActor
@Observable
final class ExtensionManager: NSObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case mustRunFromApplications
        case activating
        case needsApproval
        case notConfigured
        case ready
        case failed(String)
    }

    private enum RequestKind {
        case properties
        case activation
        case deactivation
    }

    private(set) var state: State = .checking
    private(set) var isFilterEnabled = false

    @ObservationIgnored private var requestKinds: [ObjectIdentifier: RequestKind] = [:]
    @ObservationIgnored private var filterChange: Task<Void, any Error>?
    @ObservationIgnored private let log = Log.logger("app.extension")

    private var filterIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: FaradayInfoKey.filterBundleIdentifier) as? String ?? ""
    }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private var bundledFilterVersion: String? {
        let plist = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions/\(filterIdentifier).systemextension/Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String
    }

    func refresh() {
        submit(.propertiesRequest(forExtensionWithIdentifier: filterIdentifier, queue: .main), as: .properties)
    }

    func install() {
        guard isInApplicationsFolder else {
            state = .mustRunFromApplications
            return
        }
        state = .activating
        submit(.activationRequest(forExtensionWithIdentifier: filterIdentifier, queue: .main), as: .activation)
    }

    func uninstall() async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            if manager.providerConfiguration != nil {
                try await manager.removeFromPreferences()
            }
        } catch {
            log.error("Removing filter configuration failed: \(error.localizedDescription, privacy: .public)")
        }
        isFilterEnabled = false
        submit(.deactivationRequest(forExtensionWithIdentifier: filterIdentifier, queue: .main), as: .deactivation)
    }

    func configureFilter() async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            if manager.providerConfiguration == nil {
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                manager.providerConfiguration = configuration
                manager.localizedDescription = "Faraday"
                manager.isEnabled = true
                try await manager.saveToPreferences()
            }
            isFilterEnabled = manager.isEnabled
            state = .ready
        } catch {
            state = .failed("Couldn't set up the filter: \(error.localizedDescription)")
        }
    }

    func setFilterEnabled(_ enabled: Bool) async throws {
        let previous = filterChange
        let change = Task { @MainActor in
            _ = try? await previous?.value
            try await self.applyFilterEnabled(enabled)
        }
        filterChange = change
        try await change.value
    }

    func reloadFilterState() async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            isFilterEnabled = manager.isEnabled
            if [.checking, .ready, .notConfigured].contains(state) {
                state = manager.providerConfiguration != nil ? .ready : .notConfigured
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func applyFilterEnabled(_ enabled: Bool) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard manager.providerConfiguration != nil else {
            isFilterEnabled = false
            state = .notConfigured
            throw FilterSetupError.notConfigured
        }
        if manager.isEnabled != enabled {
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            log.info("Filter \(enabled ? "enabled" : "disabled", privacy: .public)")
        }
        isFilterEnabled = enabled
    }

    private func submit(_ request: OSSystemExtensionRequest, as kind: RequestKind) {
        requestKinds[ObjectIdentifier(request)] = kind
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionManager: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing filter \(existing.bundleShortVersion, privacy: .public) with \(replacement.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let kind = requestKinds.removeValue(forKey: ObjectIdentifier(request))
        switch (kind, result) {
        case (_, .willCompleteAfterReboot):
            state = .failed("Restart your Mac to finish the filter installation.")
        case (.activation, _):
            Task { await configureFilter() }
        case (.deactivation, _):
            state = .notInstalled
        default:
            break
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let kind = requestKinds.removeValue(forKey: ObjectIdentifier(request))
        let code = (error as? OSSystemExtensionError)?.code
        switch code {
        case .extensionNotFound where kind == .properties:
            state = .notInstalled
        case .unsupportedParentBundleLocation:
            state = .mustRunFromApplications
        default:
            log.error("System extension request failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let current = properties.filter { !$0.isUninstalling }
        if current.contains(where: \.isAwaitingUserApproval) {
            state = .needsApproval
        } else if let active = current.first(where: \.isEnabled) {
            if let bundled = bundledFilterVersion, active.bundleVersion != bundled {
                log.info("Updating filter from \(active.bundleVersion, privacy: .public) to \(bundled, privacy: .public)")
                install()
            } else {
                Task { await reloadFilterState() }
            }
        } else {
            state = .notInstalled
        }
    }
}
