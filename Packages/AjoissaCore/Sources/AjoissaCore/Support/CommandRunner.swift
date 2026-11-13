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

        // Both streams are read as the program writes; a program that fills a pipe nobody reads would hang.
        let collectedOutput = Collected(reading: output.fileHandleForReading)
        let collectedErrorOutput = Collected(reading: errorOutput.fileHandleForReading)
        defer {
            collectedOutput.stop()
            collectedErrorOutput.stop()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + Self.patience) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw .timedOut(after: timeout)
        }
        // Normally both streams end as the program exits. If the program left something running that still holds
        // them open, they never end; what the program itself wrote has arrived by then, so stop waiting.
        let deadline = DispatchTime.now() + Self.patience
        collectedOutput.waitForEnd(until: deadline)
        collectedErrorOutput.waitForEnd(until: deadline)
        return CommandResult(
            exitCode: process.terminationStatus,
            output: collectedOutput.text,
            errorOutput: collectedErrorOutput.text
        )
    }

    /// Everything a stream has delivered so far, gathered on a background queue as it arrives.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)
        private let handle: FileHandle

        init(reading handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self.ended.signal()
                } else {
                    self.lock.withLock { self.data.append(chunk) }
                }
            }
        }

        func waitForEnd(until deadline: DispatchTime) {
            _ = ended.wait(timeout: deadline)
        }

        func stop() {
            handle.readabilityHandler = nil
        }

        var text: String {
            let data = lock.withLock { self.data }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }
}
