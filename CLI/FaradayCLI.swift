import Foundation
import FaradayControl
import FaradayCore

@main
struct FaradayCLI {
    static let usage = """
    USAGE: faraday <command> [options]

    COMMANDS:
      list                          Booted simulators and their network state
      on  [<udid>|<name>|booted]    Cut all network access of a simulator (default: the booted one)
      off [<udid>|<name>|booted]    Restore network access of a simulator
      all-online                    Bring every simulator back online
      status                        Filter extension status
      kill-existing on|off          Also cut connections already open when going offline (default: on)
      shim install [<target>]       Load the app shim into apps the simulator launches from now on
      shim uninstall [<target>]     Stop loading the shim into newly launched apps
      shim status [<target>]        Whether the shim is injected and what it reports
      shim env                      Environment variable that loads the shim through an Xcode scheme
      shim path                     Location of FaradayShim.dylib

    OPTIONS:
      --json                        Machine-readable output
      --no-status-bar               Leave the simulator status bar untouched
      --shim-only                   Only change what the shim reports in apps; leave the filter alone
      -h, --help                    Show this help
    """

    enum ExitCode: Int32 {
        case success = 0
        case usage = 1
        case extensionUnavailable = 2
        case simulator = 3
        case missingShim = 4
    }

    struct Failure: Error {
        let code: ExitCode
        let message: String
    }

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let json = arguments.removeAll(matching: "--json")
        let statusBar = !arguments.removeAll(matching: "--no-status-bar")
        let shimOnly = arguments.removeAll(matching: "--shim-only")
        if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            exit(arguments.isEmpty ? ExitCode.usage.rawValue : ExitCode.success.rawValue)
        }

        do {
            let command = Command(json: json, statusBar: statusBar, shimOnly: shimOnly)
            try await command.run(arguments.removeFirst(), arguments)
            exit(ExitCode.success.rawValue)
        } catch let failure as Failure {
            warn(failure.message)
            exit(failure.code.rawValue)
        } catch {
            warn(error.localizedDescription)
            exit(ExitCode.extensionUnavailable.rawValue)
        }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("faraday: \(message)\n".utf8))
}

struct Command {
    let json: Bool
    let statusBar: Bool
    let shimOnly: Bool
    let simctl = Simctl()

    func run(_ name: String, _ arguments: [String]) async throws {
        switch name {
        case "list":
            try await list()
        case "on", "off":
            try await setOffline(name == "on", target: arguments.first)
        case "all-online":
            try await allOnline()
        case "status":
            try await status()
        case "kill-existing":
            guard let value = arguments.first, ["on", "off"].contains(value) else {
                throw FaradayCLI.Failure(code: .usage, message: "kill-existing expects on or off")
            }
            try await makeClient().setKillExistingConnections(value == "on")
            output(["result": "ok"], text: "Kill existing connections: \(value).")
        case "shim":
            try shim(arguments)
        default:
            throw FaradayCLI.Failure(code: .usage, message: "unknown command '\(name)'\n\n\(FaradayCLI.usage)")
        }
    }

    // MARK: Commands

    private func list() async throws {
        let booted = try bootedSimulators()
        let offline = shimOnly ? nil : (try? await makeClient().status())?.policy.offlineSimulators
        if json {
            struct Row: Encodable {
                let udid: String
                let name: String
                let runtime: String
                let offline: Bool?
                let reachabilityReportsOffline: Bool
            }
            printJSON(booted.map {
                Row(
                    udid: $0.udid.rawValue,
                    name: $0.name,
                    runtime: $0.runtime,
                    offline: offline?.contains($0.udid),
                    reachabilityReportsOffline: ReachabilityShim.isOffline($0.udid)
                )
            })
            return
        }
        if booted.isEmpty {
            print("No booted simulators.")
        }
        for simulator in booted {
            let reachability = ReachabilityShim.isOffline(simulator.udid) ? "offline" : "online"
            var line = "\(simulator.udid)  \(simulator.name) (\(simulator.runtime))"
            if !shimOnly {
                let traffic = offline.map { $0.contains(simulator.udid) ? "OFFLINE" : "online" } ?? "unknown (filter unreachable)"
                line += "  traffic: \(traffic)"
            }
            print(line + "  apps see: \(reachability)")
        }
    }

    private func setOffline(_ offline: Bool, target: String?) async throws {
        let booted = try bootedSimulators()
        let simulator = try resolve(target, among: booted)
        if !shimOnly {
            let client = try makeClient()
            try await client.setBootedSimulators(booted.map(\.udid))
            try await client.setOffline(offline, udid: simulator.udid)
        }
        updateReachability(offline: offline, udid: simulator.udid)
        if statusBar {
            do {
                if offline {
                    try simctl.showOfflineStatusBar(simulator.udid)
                } else {
                    try simctl.clearStatusBar(simulator.udid)
                }
            } catch {
                warn("status bar not updated: \(error.localizedDescription)")
            }
        }
        output(
            ["udid": simulator.udid.rawValue, "offline": offline ? "true" : "false"],
            text: "\(simulator.name) (\(simulator.udid)) is \(offline ? "offline" : "online")\(shimOnly ? " for apps with the shim" : "")."
        )
    }

    private func allOnline() async throws {
        if !shimOnly {
            try await makeClient().setAllOnline()
        }
        let directory = ReachabilityShim.stateDirectory
        let stateFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in stateFiles where file.pathExtension == "offline" {
            try? FileManager.default.removeItem(at: file)
        }
        for simulator in (try? simctl.bootedSimulators()) ?? [] {
            try? simctl.postShimStateChange(simulator.udid)
            if statusBar {
                try? simctl.clearStatusBar(simulator.udid)
            }
        }
        output(["result": "ok"], text: "All simulators are online.")
    }

    private func status() async throws {
        let status = try await makeClient().status()
        if json {
            printJSON(status)
            return
        }
        print("Extension \(status.extensionVersion), running since \(status.startedAt.formatted())")
        print("Filter: \(status.isFilterRunning ? "running" : "not running")")
        print("Offline: \(status.policy.offlineSimulators.isEmpty ? "none" : status.policy.offlineSimulators.map(\.rawValue).sorted().joined(separator: ", "))")
        print("Kill existing connections: \(status.policy.killExistingConnections ? "on" : "off")")
        print("Dropped flows: \(status.droppedFlows.isEmpty ? "none" : status.droppedFlows.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        print("Watched open flows: \(status.trackedFlows.values.reduce(0, +))")
        print("Flows from unidentified simulator processes: \(status.unidentifiedSimulatorFlows)")
    }

    private func shim(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            throw FaradayCLI.Failure(code: .usage, message: "shim expects install, uninstall, status, env or path")
        }
        let target = arguments.dropFirst().first
        switch action {
        case "path":
            print(try shimLibrary().path)
        case "env":
            let library = try shimLibrary()
            if json {
                printJSON(["DYLD_INSERT_LIBRARIES": library.path])
            } else {
                print("Add this to your scheme under Run → Arguments → Environment Variables:")
                print("DYLD_INSERT_LIBRARIES=\(library.path)")
            }
        case "install", "uninstall":
            let simulator = try resolve(target, among: try bootedSimulators())
            do {
                if action == "install" {
                    try simctl.injectShim(try shimLibrary(), into: simulator.udid)
                } else {
                    try simctl.removeShim(from: simulator.udid)
                }
            } catch let failure as FaradayCLI.Failure {
                throw failure
            } catch {
                throw FaradayCLI.Failure(code: .simulator, message: error.localizedDescription)
            }
            let text = action == "install"
                ? "\(simulator.name) now loads the Faraday shim into apps it launches. Relaunch apps that are already running."
                : "\(simulator.name) no longer loads the Faraday shim. Relaunch apps that are already running."
            output(["udid": simulator.udid.rawValue, "injected": action == "install" ? "true" : "false"], text: text)
        case "status":
            let simulator = try resolve(target, among: try bootedSimulators())
            let injected = simctl.isShimInjected(simulator.udid)
            let offline = ReachabilityShim.isOffline(simulator.udid)
            output(
                ["udid": simulator.udid.rawValue, "injected": "\(injected)", "reportsOffline": "\(offline)"],
                text: "\(simulator.name): shim \(injected ? "injected" : "not injected"); apps see \(offline ? "offline" : "online")."
            )
        default:
            throw FaradayCLI.Failure(code: .usage, message: "unknown shim action '\(action)'")
        }
    }

    // MARK: Helpers

    private func updateReachability(offline: Bool, udid: SimulatorUDID) {
        do {
            try ReachabilityShim.setOffline(offline, udid: udid)
            try simctl.postShimStateChange(udid)
        } catch {
            warn("reachability state not updated: \(error.localizedDescription)")
        }
    }

    private func shimLibrary() throws -> URL {
        guard let library = ReachabilityShim.locateLibrary() else {
            throw FaradayCLI.Failure(
                code: .missingShim,
                message: "\(ReachabilityShim.libraryName) wasn't found next to faraday. Run the CLI from Faraday.app or set FARADAY_SHIM_PATH."
            )
        }
        return library
    }

    private func resolve(_ target: String?, among booted: [Simulator]) throws -> Simulator {
        if let target, target != "booted" {
            if let udid = SimulatorUDID(target), let match = booted.first(where: { $0.udid == udid }) {
                return match
            }
            let byName = booted.filter { $0.name == target }
            if byName.count == 1 {
                return byName[0]
            }
            let reason = byName.isEmpty ? "no booted simulator matches '\(target)'" : "several booted simulators are named '\(target)'; pass a UDID"
            throw FaradayCLI.Failure(code: .simulator, message: reason)
        }
        switch booted.count {
        case 0:
            throw FaradayCLI.Failure(code: .simulator, message: "no booted simulator")
        case 1:
            return booted[0]
        default:
            let names = booted.map { "  \($0.udid)  \($0.name) (\($0.runtime))" }.joined(separator: "\n")
            throw FaradayCLI.Failure(code: .simulator, message: "several simulators are booted; pass a UDID:\n\(names)")
        }
    }

    private func bootedSimulators() throws -> [Simulator] {
        do {
            return try simctl.bootedSimulators()
        } catch {
            throw FaradayCLI.Failure(code: .simulator, message: error.localizedDescription)
        }
    }

    private func makeClient() throws -> ControlClient {
        do {
            return try ControlClient()
        } catch {
            throw FaradayCLI.Failure(code: .extensionUnavailable, message: error.localizedDescription)
        }
    }

    private func output(_ values: [String: String], text: String) {
        if json {
            printJSON(values)
        } else {
            print(text)
        }
    }

    private func printJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

private extension Array where Element == String {
    mutating func removeAll(matching flag: String) -> Bool {
        let count = self.count
        removeAll { $0 == flag }
        return self.count != count
    }
}
