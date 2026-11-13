import Foundation

/// What a finished command left behind.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let errorOutput: String

    public init(exitCode: Int32, output: String = "", errorOutput: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }
}

public enum CommandError: Error, Sendable, Equatable {
    /// The program could not be started at all.
    case notStarted(reason: String)
    /// The program was still running after the time it was given, and was stopped.
    case timedOut(after: TimeInterval)
}

/// Runs a program and waits for it. The engine reaches other programs only through this, so tests can stand in for them.
public protocol CommandRunner: Sendable {
    /// - Parameters:
    ///   - executable: Absolute path of the program.
    ///   - arguments: Passed as they are. No shell is involved.
    ///   - timeout: Seconds after which the program is stopped.
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult
}

/// Runs programs on this Mac.
public struct ProcessCommandRunner: CommandRunner {
    /// How long to wait for a stopped program to go away, and for its output to end, before giving up on either.
    private static let patience: TimeInterval = 2

    public init() {}

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw .notStarted(reason: error.localizedDescription)
        }

        // Both streams are drained while the program runs; a program that fills a pipe nobody reads would hang.
        let reading = DispatchGroup()
        let collectedOutput = Self.collect(output, in: reading)
        let collectedErrorOutput = Self.collect(errorOutput, in: reading)

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + Self.patience) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw .timedOut(after: timeout)
        }
        // A program can exit while something it started still holds the pipe open, so the wait has a limit.
        _ = reading.wait(timeout: .now() + Self.patience)
        return CommandResult(
            exitCode: process.terminationStatus,
            output: collectedOutput.text,
            errorOutput: collectedErrorOutput.text
        )
    }

    private static func collect(_ pipe: Pipe, in group: DispatchGroup) -> Collected {
        let collected = Collected()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async(group: group) {
            collected.set(handle.readDataToEndOfFile())
        }
        return collected
    }

    /// Output read on another thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ data: Data) {
            lock.withLock { self.data = data }
        }

        var text: String {
            let data = lock.withLock { self.data }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }
}
