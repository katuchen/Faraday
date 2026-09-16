import Foundation

public enum SimulatorMarkers {
    public static let udidEnvironmentKey = "SIMULATOR_UDID"
    public static let launchdSimName = "launchd_sim"

    static let deviceSetDirectories = ["/CoreSimulator/Devices/", "/XCTestDevices/", "/Simulator Devices/"]

    static let runtimeRootMarker = ".simruntime/Contents/Resources/RuntimeRoot/"
    static let coreSimulatorFrameworkMarker = "/CoreSimulator.framework/"

    public static func udid(inPath path: String) -> SimulatorUDID? {
        for directory in deviceSetDirectories {
            var searchRange = path.startIndex..<path.endIndex
            while let found = path.range(of: directory, range: searchRange) {
                if let udid = SimulatorUDID(path[found.upperBound...].prefix(36)) {
                    return udid
                }
                searchRange = found.upperBound..<path.endIndex
            }
        }
        return nil
    }

    public static func isRuntimeRootPath(_ path: String) -> Bool {
        path.contains(runtimeRootMarker)
    }

    public static func isCoreSimulatorResourcePath(_ path: String) -> Bool {
        path.contains(coreSimulatorFrameworkMarker) && path.contains("/Resources/")
    }

    public static func udid(inEnvironment environment: [String]) -> SimulatorUDID? {
        let prefix = udidEnvironmentKey + "="
        guard let entry = environment.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return SimulatorUDID(entry.dropFirst(prefix.count))
    }

    public static func isLaunchdSim(executablePath: String) -> Bool {
        (executablePath as NSString).lastPathComponent == launchdSimName
    }

    public static func udid(inArguments arguments: [String]) -> SimulatorUDID? {
        arguments.lazy.compactMap(udid(inPath:)).first
    }
}
