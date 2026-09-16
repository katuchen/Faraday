import Foundation
import FaradayCore
import Testing
@testable import FaradayControl

struct ReachabilityShimTests {
    let library = "/Applications/Faraday.app/Contents/Resources/FaradayShim.dylib"

    @Test func insertsIntoEmptyValue() {
        #expect(ReachabilityShim.insertingLibrary(library, into: "") == library)
    }

    @Test func keepsOtherInjectedLibraries() {
        #expect(ReachabilityShim.insertingLibrary(library, into: "/tmp/Other.dylib") == "/tmp/Other.dylib:\(library)")
    }

    @Test func replacesAnOlderShimPath() {
        let value = ReachabilityShim.insertingLibrary(library, into: "/old/place/FaradayShim.dylib:/tmp/Other.dylib")
        #expect(value == "/tmp/Other.dylib:\(library)")
    }

    @Test func removesOnlyTheShim() {
        #expect(ReachabilityShim.removingLibrary(from: "/tmp/Other.dylib:\(library)") == "/tmp/Other.dylib")
        #expect(ReachabilityShim.removingLibrary(from: library) == "")
    }

    @Test func stateFileFollowsShimConvention() {
        let udid = SimulatorUDID("4AB6C209-AF1B-406A-8371-438B730CB7F5")!
        let path = ReachabilityShim.stateFile(for: udid).path
        #expect(path.hasSuffix("/Library/Application Support/Faraday/State/4AB6C209-AF1B-406A-8371-438B730CB7F5.offline"))
    }
}
