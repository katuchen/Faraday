import Foundation
import Synchronization
import Testing
@testable import FaradayCore

func auditToken(pid: pid_t, version: Int32 = 1) -> Data {
    var values = [UInt32](repeating: 0, count: 8)
    values[5] = UInt32(pid)
    values[7] = UInt32(bitPattern: version)
    return values.withUnsafeBytes { Data($0) }
}

final class FakeInspector: ProcessInspecting {
    struct FakeProcess {
        var path: String?
        var environment: [String] = []
        var arguments: [String] = []
        var parent: pid_t?
    }

    let processes: [pid_t: FakeProcess]
    private let argumentReads = Atomic<Int>(0)
    private let pathReads = Atomic<Int>(0)

    init(_ processes: [pid_t: FakeProcess]) {
        self.processes = processes
    }

    var argumentReadCount: Int { argumentReads.load(ordering: .relaxed) }
    var pathReadCount: Int { pathReads.load(ordering: .relaxed) }

    func executablePath(auditToken: Data) -> String? {
        guard let key = ProcessKey(auditToken: auditToken) else { return nil }
        return executablePath(pid: key.pid)
    }

    func executablePath(pid: pid_t) -> String? {
        pathReads.add(1, ordering: .relaxed)
        return processes[pid]?.path
    }

    func arguments(pid: pid_t) -> ProcessArguments? {
        argumentReads.add(1, ordering: .relaxed)
        guard let process = processes[pid], let path = process.path else { return nil }
        return ProcessArguments(executablePath: path, arguments: process.arguments, environment: process.environment)
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        processes[pid]?.parent
    }
}

struct SimulatorResolverTests {
    static let udid = SimulatorUDID("4AB6C209-AF1B-406A-8371-438B730CB7F5")!
    static let otherUDID = SimulatorUDID("36DA1BDB-EDE2-40A3-B016-1018008FB749")!
    static let runtimeRoot = "/Library/Developer/CoreSimulator/Volumes/iOS_23A343/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot"
    static let launchdSim = FakeInspector.FakeProcess(
        path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/launchd_sim",
        arguments: ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"],
        parent: 1
    )

    @Test func auditTokenLayout() throws {
        let key = try #require(ProcessKey(auditToken: auditToken(pid: 4242, version: 7)))
        #expect(key == ProcessKey(pid: 4242, version: 7))
        #expect(ProcessKey(auditToken: Data([1, 2, 3])) == nil)
    }

    @Test func appInDeviceFolder() {
        let inspector = FakeInspector([
            500: .init(path: "/Users/me/Library/Developer/CoreSimulator/Devices/\(Self.udid)/data/Containers/Bundle/Application/X/NetProbe.app"),
        ])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 500), processAuditToken: auditToken(pid: 500)) == .simulator(Self.udid))
        #expect(inspector.argumentReadCount == 0)
    }

    @Test func hostProcessIsNotInspectedFurther() {
        let inspector = FakeInspector([600: .init(path: "/Applications/Safari.app")])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 600), processAuditToken: nil) == .host)
        #expect(inspector.argumentReadCount == 0)
    }

    @Test func runtimeRootProcessWithEnvironment() {
        let inspector = FakeInspector([
            700: .init(path: Self.runtimeRoot + "/usr/libexec/apsd", environment: ["SIMULATOR_UDID=\(Self.otherUDID)"]),
        ])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 700), processAuditToken: nil) == .simulator(Self.otherUDID))
    }

    @Test func runtimeRootProcessViaLaunchdSimAncestor() {
        let inspector = FakeInspector([
            100: Self.launchdSim,
            701: .init(path: Self.runtimeRoot + "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.Networking.xpc", parent: 702),
            702: .init(path: Self.runtimeRoot + "/usr/libexec/runningboardd", parent: 100),
        ])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 701), processAuditToken: nil) == .simulator(Self.udid))
    }

    static let coreSimulatorResources = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources"

    @Test func coreSimulatorHelperOfSimulator() {
        let inspector = FakeInspector([
            100: Self.launchdSim,
            800: .init(path: Self.coreSimulatorResources + "/Platforms/iphoneos/usr/libexec/CoreSimulatorBridge", parent: 100),
            801: .init(path: Self.coreSimulatorResources + "/Platforms/iphoneos/usr/libexec/dtdeviceinfod", environment: ["SIMULATOR_UDID=\(Self.otherUDID)"], parent: 1),
        ])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 800), processAuditToken: nil) == .simulator(Self.udid))
        #expect(resolver.origin(appAuditToken: auditToken(pid: 801), processAuditToken: nil) == .simulator(Self.otherUDID))
    }

    @Test func coreSimulatorHostToolIsHost() {
        let inspector = FakeInspector([802: .init(path: Self.coreSimulatorResources + "/bin/simdiskimaged", parent: 1)])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 802), processAuditToken: nil) == .host)
    }

    @Test func launchdSimItself() {
        let inspector = FakeInspector([100: Self.launchdSim])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 100), processAuditToken: nil) == .simulator(Self.udid))
    }

    @Test func runtimeRootProcessWithoutAnyDeviceHint() {
        let inspector = FakeInspector([703: .init(path: Self.runtimeRoot + "/usr/libexec/apsd", parent: 1)])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 703), processAuditToken: nil) == .unidentifiedSimulator)
    }

    @Test func delegatedFlowUsesSourceApp() {
        let inspector = FakeInspector([
            500: .init(path: "/Users/me/Library/Developer/CoreSimulator/Devices/\(Self.udid)/data/Containers/Bundle/Application/X/NetProbe.app"),
            88: .init(path: "/usr/sbin/mDNSResponder"),
        ])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 500), processAuditToken: auditToken(pid: 88)) == .simulator(Self.udid))
        #expect(resolver.origin(appAuditToken: auditToken(pid: 88), processAuditToken: auditToken(pid: 500)) == .simulator(Self.udid))
    }

    @Test func resultsAreCachedPerProcessInstance() {
        let inspector = FakeInspector([600: .init(path: "/Applications/Safari.app")])
        let resolver = SimulatorResolver(inspector: inspector)
        _ = resolver.origin(appAuditToken: auditToken(pid: 600, version: 1), processAuditToken: nil)
        _ = resolver.origin(appAuditToken: auditToken(pid: 600, version: 1), processAuditToken: nil)
        #expect(inspector.pathReadCount == 1)
        _ = resolver.origin(appAuditToken: auditToken(pid: 600, version: 2), processAuditToken: nil)
        #expect(inspector.pathReadCount == 2)
    }

    @Test func vanishedProcessIsHostAndNotCached() {
        let inspector = FakeInspector([:])
        let resolver = SimulatorResolver(inspector: inspector)
        #expect(resolver.origin(appAuditToken: auditToken(pid: 999), processAuditToken: nil) == .host)
        let readsForOneResolution = inspector.pathReadCount
        _ = resolver.origin(appAuditToken: auditToken(pid: 999), processAuditToken: nil)
        #expect(inspector.pathReadCount == 2 * readsForOneResolution)
    }
}
