import Foundation
import FaradayCore

public enum ReachabilityShim {
    public static let libraryName = "FaradayShim.dylib"
    public static let stateChangedNotification = "com.faraday.state-changed"
    static let injectionVariable = "DYLD_INSERT_LIBRARIES"

    public static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Faraday/State", directoryHint: .isDirectory)
    }

    public static func stateFile(for udid: SimulatorUDID) -> URL {
        stateDirectory.appending(path: "\(udid.rawValue).offline")
    }

    public static func isOffline(_ udid: SimulatorUDID) -> Bool {
        FileManager.default.fileExists(atPath: stateFile(for: udid).path)
    }

    public static func setOffline(_ offline: Bool, udid: SimulatorUDID) throws {
        let file = stateFile(for: udid)
        if offline {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try Data().write(to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public static func locateLibrary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["FARADAY_SHIM_PATH"] {
            return URL(fileURLWithPath: override)
        }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: libraryName))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appending(path: "../Resources/\(libraryName)").standardizedFileURL)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func insertingLibrary(_ library: String, into current: String) -> String {
        var entries = current.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        entries.removeAll { ($0 as NSString).lastPathComponent == libraryName }
        entries.append(library)
        return entries.joined(separator: ":")
    }

    static func removingLibrary(from current: String) -> String {
        current.split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && ($0 as NSString).lastPathComponent != libraryName }
            .joined(separator: ":")
    }
}

extension Simctl {
    public func postShimStateChange(_ udid: SimulatorUDID) throws {
        try spawn(udid, ["notifyutil", "-p", ReachabilityShim.stateChangedNotification])
    }

    public func injectedLibraries(_ udid: SimulatorUDID) throws -> String {
        try spawn(udid, ["launchctl", "getenv", ReachabilityShim.injectionVariable]).outputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isShimInjected(_ udid: SimulatorUDID) -> Bool {
        (try? injectedLibraries(udid))?.split(separator: ":")
            .contains { ($0 as NSString).lastPathComponent == ReachabilityShim.libraryName } ?? false
    }

    public func injectShim(_ library: URL, into udid: SimulatorUDID) throws {
        let value = ReachabilityShim.insertingLibrary(library.path, into: try injectedLibraries(udid))
        try spawn(udid, ["launchctl", "setenv", ReachabilityShim.injectionVariable, value])
    }

    public func removeShim(from udid: SimulatorUDID) throws {
        let value = ReachabilityShim.removingLibrary(from: try injectedLibraries(udid))
        if value.isEmpty {
            try spawn(udid, ["launchctl", "unsetenv", ReachabilityShim.injectionVariable])
        } else {
            try spawn(udid, ["launchctl", "setenv", ReachabilityShim.injectionVariable, value])
        }
    }
}
