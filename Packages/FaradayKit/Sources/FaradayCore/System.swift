import CFaradaySupport
import os

public enum Log {
    public static let subsystem = "Faraday"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

public enum BootSession {
    public static var identifier: String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard faraday_boot_session_uuid(&buffer, buffer.count) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
