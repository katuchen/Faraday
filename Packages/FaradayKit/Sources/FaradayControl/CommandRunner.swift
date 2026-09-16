import Foundation
import Synchronization

public struct CommandResult: Sendable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public var outputString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorString: String { String(decoding: standardError, as: UTF8.self) }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public var command: [String]
    public var message: String

    public var errorDescription: String? { "\(command.joined(separator: " ")): \(message)" }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let output = Mutex(Data())
        let errorOutput = Mutex(Data())
        let drained = DispatchGroup()
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        drained.enter()
        DispatchQueue.global().async {
            let data = outputHandle.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            let data = errorHandle.readDataToEndOfFile()
            errorOutput.withLock { $0 = data }
            drained.leave()
        }

        let command = [executable] + arguments
        do {
            try process.run()
        } catch {
            throw CommandError(command: command, message: error.localizedDescription)
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw CommandError(command: command, message: "timed out after \(Int(timeout)) s")
        }
        drained.wait()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: output.withLock { $0 },
            standardError: errorOutput.withLock { $0 }
        )
    }
}
