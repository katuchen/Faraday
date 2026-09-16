import Foundation
import Testing
@testable import FaradayControl

struct SimctlTests {
    @Test func parsesDeviceList() throws {
        let url = try #require(Bundle.module.url(forResource: "simctl-list-devices", withExtension: "json", subdirectory: "Fixtures"))
        let simulators = try Simctl.parseDeviceList(Data(contentsOf: url))
        #expect(simulators.count == 3)
        let booted = simulators.filter(\.isBooted)
        #expect(booted.map(\.name) == ["iPhone 17 Pro"])
        #expect(booted.first?.runtime == "iOS 26.0")
        #expect(booted.first?.udid.rawValue == "4AB6C209-AF1B-406A-8371-438B730CB7F5")
    }

    @Test(arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-26-0", "iOS 26.0"),
        ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "iOS 26.5"),
        ("com.apple.CoreSimulator.SimRuntime.xrOS-27-0", "xrOS 27.0"),
        ("weird", "weird"),
    ])
    func runtimeDisplayNames(identifier: String, expected: String) {
        #expect(Simctl.runtimeDisplayName(identifier) == expected)
    }

    @Test func commandFailureSurfacesStandardError() {
        struct FailingRunner: CommandRunning {
            func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
                CommandResult(status: 164, standardOutput: Data(), standardError: Data("Invalid device: nope\n".utf8))
            }
        }
        #expect {
            try Simctl(runner: FailingRunner()).bootedSimulators()
        } throws: { error in
            (error as? CommandError)?.message == "Invalid device: nope"
        }
    }

    @Test func realCommandRunner() throws {
        let result = try ProcessCommandRunner().run("/bin/echo", ["hello"], timeout: 5)
        #expect(result.status == 0)
        #expect(result.outputString == "hello\n")
    }
}
