import Testing
@testable import FaradayCore

struct SimulatorMarkersTests {
    let udid = "4AB6C209-AF1B-406A-8371-438B730CB7F5"

    @Test func udidFromInstalledAppPath() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/0C4E5A51-6B8E-4A37-9E5E-0B3C4F2D1A10/NetProbe.app"
        #expect(SimulatorMarkers.udid(inPath: path)?.rawValue == udid)
    }

    @Test func udidFromXCTestClonePath() {
        let path = "/Users/me/Library/Developer/XCTestDevices/\(udid)/data/Containers/Bundle/Application/X/App.app/App"
        #expect(SimulatorMarkers.udid(inPath: path)?.rawValue == udid)
    }

    @Test func udidFromPreviewsPath() {
        let path = "/Users/me/Library/Developer/Xcode/UserData/Previews/Simulator Devices/\(udid)/data/Containers/Bundle/Application/X/App.app"
        #expect(SimulatorMarkers.udid(inPath: path)?.rawValue == udid)
    }

    @Test func udidIsNormalizedToUppercase() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid.lowercased())/data/tmp"
        #expect(SimulatorMarkers.udid(inPath: path)?.rawValue == udid)
    }

    @Test(arguments: [
        "/Applications/Safari.app/Contents/MacOS/Safari",
        "/usr/libexec/nsurlsessiond",
        "/Library/Developer/CoreSimulator/Devices/not-a-udid/data",
        "/Library/Developer/CoreSimulator/Volumes/iOS_23A343/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/nsurlsessiond",
    ])
    func pathsWithoutDeviceFolder(path: String) {
        #expect(SimulatorMarkers.udid(inPath: path) == nil)
    }

    @Test func runtimeRootPaths() {
        let simulatorDaemon = "/Library/Developer/CoreSimulator/Volumes/iOS_23A343/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/nsurlsessiond"
        let cryptexDaemon = "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.XWHPJQ/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/apsd"
        #expect(SimulatorMarkers.isRuntimeRootPath(simulatorDaemon))
        #expect(SimulatorMarkers.isRuntimeRootPath(cryptexDaemon))
        #expect(!SimulatorMarkers.isRuntimeRootPath("/usr/libexec/nsurlsessiond"))
    }

    @Test func coreSimulatorResourcePaths() {
        #expect(SimulatorMarkers.isCoreSimulatorResourcePath("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/usr/libexec/CoreSimulatorBridge"))
        #expect(!SimulatorMarkers.isCoreSimulatorResourcePath("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService"))
        #expect(!SimulatorMarkers.isCoreSimulatorResourcePath("/Applications/Xcode.app/Contents/Resources/x"))
    }

    @Test func udidFromEnvironment() {
        let environment = ["HOME=/Users/me", "SIMULATOR_UDID=\(udid.lowercased())", "SIMULATOR_RUNTIME_VERSION=26.0"]
        #expect(SimulatorMarkers.udid(inEnvironment: environment)?.rawValue == udid)
        #expect(SimulatorMarkers.udid(inEnvironment: ["HOME=/Users/me"]) == nil)
        #expect(SimulatorMarkers.udid(inEnvironment: ["SIMULATOR_UDID=garbage"]) == nil)
    }

    @Test func udidFromLaunchdSimArguments() {
        let arguments = ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]
        #expect(SimulatorMarkers.udid(inArguments: arguments)?.rawValue == udid)
        #expect(SimulatorMarkers.isLaunchdSim(executablePath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/launchd_sim"))
        #expect(!SimulatorMarkers.isLaunchdSim(executablePath: "/sbin/launchd"))
    }
}
