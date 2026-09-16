import AppKit
import FaradayControl
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Faraday").font(.headline)
                Spacer()
                FilterBadge(isRunning: model.isFilterRunning, isReady: model.extensionManager.state == .ready)
            }

            if model.extensionManager.state != .ready {
                SetupCard(manager: model.extensionManager)
            }

            Divider()
            simulatorList
            Divider()

            Toggle("Cut connections that are already open", isOn: Binding(
                get: { model.killExistingConnections },
                set: { enabled in Task { await model.setKillExistingConnections(enabled) } }
            ))
            .disabled(!model.isFilterReachable)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Make reachability and DNS fail in apps too", isOn: $model.injectsReachabilityShim)
                Text("Loads a small library into apps the simulators launch from now on, so NWPathMonitor and "
                     + "SCNetworkReachability report no network and name lookups fail. Relaunch apps that are already running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("All Online") { Task { await model.setAllOnline() } }
                    .disabled(model.offlineSimulators.isEmpty)
                Spacer()
                Menu("More") {
                    Button("Copy Command-Line Tool Path") {
                        copyToPasteboard(model.commandLineToolPath)
                    }
                    Button("Copy Xcode Scheme Variable for the Shim") {
                        if let variable = model.xcodeSchemeVariable {
                            copyToPasteboard(variable)
                        }
                    }
                    .disabled(model.xcodeSchemeVariable == nil)
                    Button("Uninstall Filter") { Task { await model.extensionManager.uninstall() } }
                    Divider()
                    Button("Quit Faraday") { NSApplication.shared.terminate(nil) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 360)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @ViewBuilder private var simulatorList: some View {
        if model.simulators.isEmpty {
            Text("No booted simulators. Start one in Device Hub.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.simulators) { simulator in
                HStack {
                    Image(systemName: model.isOffline(simulator) ? "network.slash" : "network")
                        .foregroundStyle(model.isOffline(simulator) ? .red : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(simulator.name)
                        Text(simulator.runtime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(simulator.udid.rawValue)
                    Spacer()
                    Toggle("Offline", isOn: Binding(
                        get: { model.isOffline(simulator) },
                        set: { offline in Task { await model.setOffline(offline, for: simulator) } }
                    ))
                    .labelsHidden()
                    .disabled(!model.canControlSimulators)
                }
            }
        }
    }
}

private struct FilterBadge: View {
    let isRunning: Bool
    let isReady: Bool

    var body: some View {
        Label(title, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(isRunning ? .green : .secondary)
    }

    private var title: String {
        if isRunning {
            "Filter running"
        } else if isReady {
            "Filter starting…"
        } else {
            "Filter off"
        }
    }
}

private struct SetupCard: View {
    let manager: ExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch manager.state {
            case .checking, .activating:
                ProgressView("Checking the network filter…")
            case .notInstalled:
                Text("Faraday cuts simulator traffic with a network filter. macOS asks you to allow it once.")
                Button("Install Filter") { manager.install() }
            case .mustRunFromApplications:
                Text("Move Faraday.app to /Applications and open it from there. macOS only installs system extensions from that folder.")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            case .needsApproval:
                Text("Allow the Faraday extension in System Settings → General → Login Items & Extensions → Network Extensions.")
                HStack {
                    Button("Open System Settings") { manager.openSystemSettings() }
                    Button("Check Again") { manager.refresh() }
                }
            case .notConfigured:
                Text("The filter's network configuration is missing.")
                Button("Set Up Filter") { Task { await manager.configureFilter() } }
            case .failed(let message):
                Text(message)
                Button("Try Again") { manager.install() }
            case .ready:
                EmptyView()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
