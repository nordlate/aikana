import Foundation

/// What a finished command left behind.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    /// What the command wrote to its standard output, byte for byte.
    public let outputData: Data
    public let errorOutput: String

    /// The standard output as text. Bytes that are not valid text become replacement characters.
    public var output: String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: outputData, as: UTF8.self)
    }

    public init(exitCode: Int32, output: String = "", errorOutput: String = "") {
        self.init(exitCode: exitCode, outputData: Data(output.utf8), errorOutput: errorOutput)
    }

    public init(exitCode: Int32, outputData: Data, errorOutput: String = "") {
        self.exitCode = exitCode
        self.outputData = outputData
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
    ///   - input: What the program reads from its standard input. `nil` for nothing.
    ///   - timeout: Seconds after which the program is stopped.
    func run(_ executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws(CommandError) -> CommandResult
}

extension CommandRunner {
    /// Runs a program that reads nothing from its standard input.
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        try run(executable, arguments: arguments, input: nil, timeout: timeout)
    }
}

/// Runs programs on this Mac.
public struct ProcessCommandRunner: CommandRunner {
    /// How long to wait for a stopped program to go away, and for its output to end, before giving up on either.
    private static let patience: TimeInterval = 2

    public init() {}

    public func run(_ executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws(CommandError) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw .notStarted(reason: error.localizedDescription)
        }
        if let input, let inputPipe {
            Self.feed(input, to: inputPipe.fileHandleForWriting)
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
        // A program ended by a signal has no exit code of its own. It gets the one a shell would report.
        let endedBySignal = process.terminationReason == .uncaughtSignal
        return CommandResult(
            exitCode: endedBySignal ? 128 + process.terminationStatus : process.terminationStatus,
            outputData: collectedOutput.data,
            errorOutput: collectedErrorOutput.text
        )
    }

    /// Writes the input on a background queue and closes the stream, so a program that does not read it, or
    /// reads it slowly, cannot hold up the caller.
    private static func feed(_ input: Data, to handle: FileHandle) {
        // A program that ends without reading must not end this one with a broken pipe signal.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            try? handle.write(contentsOf: input)
            try? handle.close()
        }
    }

    /// Everything a stream has delivered so far, gathered on a background queue as it arrives.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = Data()
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
                    self.lock.withLock { self.collected.append(chunk) }
                }
            }
        }

        func waitForEnd(until deadline: DispatchTime) {
            _ = ended.wait(timeout: deadline)
        }

        func stop() {
            handle.readabilityHandler = nil
        }

        var data: Data {
            lock.withLock { collected }
        }

        var text: String {
            // Bytes that are not valid text become replacement characters; the rest stays readable.
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: data, as: UTF8.self)
        }
    }
}
