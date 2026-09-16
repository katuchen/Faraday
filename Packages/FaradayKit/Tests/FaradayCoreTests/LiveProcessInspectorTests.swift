import Foundation
import Testing
@testable import FaradayCore

struct LiveProcessInspectorTests {
    let inspector = LiveProcessInspector()

    @Test func inspectsOwnProcess() throws {
        let pid = getpid()
        #expect(inspector.executablePath(pid: pid) != nil)
        #expect(inspector.parentPID(of: pid) != nil)
        let arguments = try #require(inspector.arguments(pid: pid))
        #expect(!arguments.arguments.isEmpty)
        #expect(arguments.environment.contains { $0.hasPrefix("PATH=") })
        #expect(BootSession.identifier != nil)
        #expect(SimulatorResolver(inspector: inspector).origin(pid: pid) == .host)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FARADAY_LIVE_UDID"] != nil))
    func resolvesEveryProcessOfBootedSimulator() throws {
        let udid = try #require(SimulatorUDID(ProcessInfo.processInfo.environment["FARADAY_LIVE_UDID"] ?? ""))
        let simulatorProcesses = inspector.allPIDs().filter { pid in
            inspector.arguments(pid: pid).flatMap { SimulatorMarkers.udid(inEnvironment: $0.environment) } == udid
        }
        #expect(simulatorProcesses.count > 20)

        let resolver = SimulatorResolver(inspector: inspector)
        let withoutEnvironment = SimulatorResolver(inspector: EnvironmentHidingInspector(base: inspector))
        var viaAncestry = 0
        for pid in simulatorProcesses {
            #expect(resolver.origin(pid: pid) == .simulator(udid), "pid \(pid): \(inspector.executablePath(pid: pid) ?? "?")")
            let origin = withoutEnvironment.origin(pid: pid)
            if origin == .simulator(udid) {
                viaAncestry += 1
            }
        }
        #expect(viaAncestry == simulatorProcesses.count)
    }
}

private struct EnvironmentHidingInspector: ProcessInspecting {
    let base: LiveProcessInspector

    func executablePath(auditToken: Data) -> String? { base.executablePath(auditToken: auditToken) }
    func executablePath(pid: pid_t) -> String? { base.executablePath(pid: pid) }
    func parentPID(of pid: pid_t) -> pid_t? { base.parentPID(of: pid) }

    func arguments(pid: pid_t) -> ProcessArguments? {
        guard var arguments = base.arguments(pid: pid) else { return nil }
        arguments.environment = []
        return arguments
    }
}
