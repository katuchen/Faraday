import Testing
@testable import FaradayCore

struct ProcessArgumentsTests {
    private func procargs2(argc: Int32, strings: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        for (index, string) in strings.enumerated() {
            bytes += Array(string.utf8) + [0]
            if index == 0 {
                bytes += [UInt8](repeating: 0, count: padding)
            }
        }
        return bytes
    }

    @Test func parsesExecutableArgumentsAndEnvironment() throws {
        let bytes = procargs2(argc: 2, strings: [
            "/usr/libexec/nsurlsessiond",
            "nsurlsessiond", "--verbose",
            "SIMULATOR_UDID=4AB6C209-AF1B-406A-8371-438B730CB7F5", "HOME=/tmp",
            "", "ptr_munge=",
        ])
        let parsed = try #require(ProcessArguments.parse(procargs2: bytes))
        #expect(parsed.executablePath == "/usr/libexec/nsurlsessiond")
        #expect(parsed.arguments == ["nsurlsessiond", "--verbose"])
        #expect(parsed.environment == ["SIMULATOR_UDID=4AB6C209-AF1B-406A-8371-438B730CB7F5", "HOME=/tmp"])
    }

    @Test func environmentMayRunToEndOfBuffer() throws {
        let bytes = procargs2(argc: 1, strings: ["/bin/tool", "tool", "A=1"], padding: 0)
        let parsed = try #require(ProcessArguments.parse(procargs2: bytes))
        #expect(parsed.environment == ["A=1"])
    }

    @Test func rejectsTruncatedRecords() {
        #expect(ProcessArguments.parse(procargs2: [1, 0]) == nil)
        #expect(ProcessArguments.parse(procargs2: procargs2(argc: 3, strings: ["/bin/tool", "tool"])) == nil)
    }
}
