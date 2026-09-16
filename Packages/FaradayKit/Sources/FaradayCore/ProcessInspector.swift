import CFaradaySupport
import Foundation
import Security

public struct ProcessKey: Hashable, Sendable {
    public let pid: pid_t
    public let version: Int32

    public init(pid: pid_t, version: Int32) {
        self.pid = pid
        self.version = version
    }

    public init?(auditToken: Data) {
        let (pid, version) = auditToken.withUnsafeBytes { raw -> (pid_t, Int32) in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (
                faraday_audit_token_pid(bytes.baseAddress, bytes.count),
                faraday_audit_token_pidversion(bytes.baseAddress, bytes.count)
            )
        }
        guard pid > 0 else { return nil }
        self.init(pid: pid, version: version)
    }
}

public protocol ProcessInspecting: Sendable {
    func executablePath(auditToken: Data) -> String?
    func executablePath(pid: pid_t) -> String?
    func arguments(pid: pid_t) -> ProcessArguments?
    func parentPID(of pid: pid_t) -> pid_t?
}

public struct LiveProcessInspector: ProcessInspecting {
    public init() {}

    public func executablePath(auditToken: Data) -> String? {
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else {
            return nil
        }
        return (url as URL).path
    }

    public func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = faraday_proc_path(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func arguments(pid: pid_t) -> ProcessArguments? {
        let capacity = faraday_arg_max()
        guard capacity > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: capacity)
        var size = capacity
        let status = buffer.withUnsafeMutableBytes { raw in
            faraday_proc_args(pid, raw.baseAddress!.assumingMemoryBound(to: CChar.self), &size)
        }
        guard status == 0 else { return nil }
        return ProcessArguments.parse(procargs2: buffer.prefix(size))
    }

    public func parentPID(of pid: pid_t) -> pid_t? {
        let parent = faraday_proc_parent(pid)
        return parent > 0 ? parent : nil
    }

    public func allPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = faraday_list_pids(&pids, Int32(pids.count))
        return Array(pids.prefix(Int(count)))
    }
}
