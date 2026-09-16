public struct ProcessArguments: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String]

    public init(executablePath: String, arguments: [String], environment: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }

    public static func parse(procargs2: some Collection<UInt8>) -> ProcessArguments? {
        let bytes = Array(procargs2)
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = 4

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        guard let executablePath = nextString() else { return nil }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }

        var environment: [String] = []
        while let entry = nextString(), !entry.isEmpty {
            environment.append(entry)
        }

        return ProcessArguments(executablePath: executablePath, arguments: arguments, environment: environment)
    }
}
