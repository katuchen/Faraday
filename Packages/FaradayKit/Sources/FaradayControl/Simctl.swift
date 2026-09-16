import Foundation
import FaradayCore

public struct Simulator: Codable, Hashable, Sendable, Identifiable {
    public var udid: SimulatorUDID
    public var name: String
    public var runtime: String
    public var state: String

    public var id: SimulatorUDID { udid }
    public var isBooted: Bool { state == "Booted" }

    public init(udid: SimulatorUDID, name: String, runtime: String, state: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
    }
}

public struct Simctl: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func bootedSimulators() throws -> [Simulator] {
        let result = try simctl(["list", "devices", "booted", "-j"])
        return try Self.parseDeviceList(result.standardOutput).filter(\.isBooted)
    }

    public func showOfflineStatusBar(_ udid: SimulatorUDID) throws {
        try simctl([
            "status_bar", udid.rawValue, "override",
            "--wifiMode", "failed",
            "--cellularMode", "failed", "--cellularBars", "0",
            "--operatorName", "No Service", "--dataNetwork", "hide",
        ])
    }

    public func clearStatusBar(_ udid: SimulatorUDID) throws {
        try simctl(["status_bar", udid.rawValue, "clear"])
    }

    @discardableResult
    public func spawn(_ udid: SimulatorUDID, _ arguments: [String]) throws -> CommandResult {
        try simctl(["spawn", udid.rawValue] + arguments)
    }

    @discardableResult
    func simctl(_ arguments: [String], timeout: TimeInterval = 60) throws -> CommandResult {
        let result = try runner.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
        guard result.status == 0 else {
            let message = result.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(command: ["xcrun", "simctl"] + arguments, message: message.isEmpty ? "exit \(result.status)" : message)
        }
        return result
    }

    public static func parseDeviceList(_ data: Data) throws -> [Simulator] {
        struct DeviceList: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
            }

            let devices: [String: [Device]]
        }

        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        return list.devices
            .flatMap { runtime, devices in
                devices.compactMap { device in
                    SimulatorUDID(device.udid).map {
                        Simulator(udid: $0, name: device.name, runtime: runtimeDisplayName(runtime), state: device.state)
                    }
                }
            }
            .sorted { ($0.runtime, $0.name, $0.udid) < ($1.runtime, $1.name, $1.udid) }
    }

    public static func runtimeDisplayName(_ identifier: String) -> String {
        let suffix = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = suffix.split(separator: "-")
        guard parts.count > 1, let platform = parts.first else { return suffix }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}
