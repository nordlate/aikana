import Foundation

/// Why a script could not be run on another machine.
public enum RemoteShellError: Error, Sendable, Equatable {
    /// The machine did not answer, or refused the connection. The text is what `ssh` said.
    case unreachable(String)
    /// The connection was made, but the script had not finished in time.
    case timedOut(after: TimeInterval)
    /// The script ran, or may have run, but did not report back as every script does.
    case broken(String)

    /// The reason, as the end of "<host> could not be reached: …" or "<host> did not answer: …".
    public var reason: String {
        switch self {
        case let .unreachable(reason): reason
        case let .timedOut(after): "no answer within \(LaunchdJobDefinition.compact(seconds: Int(after)))"
        case let .broken(reason): reason
        }
    }
}

/// A POSIX shell on a machine, reached by running one fixed program that reads a script from its input.
///
/// For another machine the program is the system `ssh` with the user's own configuration, and the command it
/// is given is always the one word `/bin/sh`: nothing from the config is ever part of the command line that
/// the remote login shell reads. Everything else travels as the script, on
/// standard input, where only `/bin/sh` reads it. That is why one way of quoting is enough, whatever shell
/// the remote user has.
///
/// Every script ends by writing a line that starts with ``marker`` to its error output. Without that line the
/// script did not run to its end, and its output is not used.
public struct RemoteShell: Sendable {
    /// The start of the line a script reports back with.
    static let marker = "ajoissa:"
    static let sshPath = "/usr/bin/ssh"
    /// How long `ssh` may take to connect.
    public static let connectTimeout: TimeInterval = 10
    /// How long an idle connection is kept for the next look.
    static let keepConnection: TimeInterval = 600
    /// A socket path longer than this is refused by the system; `ssh` adds 40 characters of its own.
    static let longestControlDirectory = 60
    /// The line every script's output starts with. Anything before it was written by the remote user's own
    /// shell startup files, not by the script, and is dropped.
    static let begin = "ajoissa:begin\n"
    /// What every script starts with: the line that marks where its output begins, and a fixed language,
    /// because messages of tools are compared and must not be translated.
    static let preamble = "printf 'ajoissa:begin\\n'\nLC_ALL=C\nexport LC_ALL\n"
    /// Characters that `ssh` reads specially in a socket path, or that would split it in two.
    static let unusableInControlPath = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "%\"'\\"))

    /// Remembers that a machine stopped answering, so that the rest of a look does not wait for it again.
    private final class Breaker: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RemoteShellError?

        var tripped: RemoteShellError? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private var breaker: Breaker?

    private let runner: any CommandRunner
    private let executable: String
    private let arguments: [String]

    /// A shell reached by running `executable` with `arguments`; the script is written to its input.
    public init(runner: any CommandRunner, executable: String, arguments: [String]) {
        self.runner = runner
        self.executable = executable
        self.arguments = arguments
    }

    /// The shell on the machine that `alias` names in the user's `~/.ssh/config`.
    ///
    /// - Parameter controlDirectory: A private folder for the socket that lets the scripts of one look share
    ///   one connection. `nil`, or a path too long for a socket, means a connection per script.
    public static func ssh(alias: String, runner: any CommandRunner, controlDirectory: URL?) -> Self {
        Self(runner: runner, executable: sshPath, arguments: sshArguments(alias: alias, controlDirectory: controlDirectory))
    }

    /// The same shell for the length of one look: once the machine does not answer, every later script fails
    /// at once with the same reason instead of waiting out its own timeout.
    public func forOneLook() -> Self {
        var shell = self
        shell.breaker = Breaker()
        return shell
    }

    /// The arguments `ssh` is run with. This is the whole of what Ajoissa adds to the user's own settings.
    static func sshArguments(alias: String, controlDirectory: URL?) -> [String] {
        var arguments = [
            // No terminal, and never a question: a key that needs a passphrase typed, or a host that is not
            // known yet, is a failure to connect, not a prompt nobody sees.
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Int(connectTimeout))",
            // A connection that has gone quiet is given up after about ten seconds, not when TCP notices.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2"
        ]
        if let controlDirectory, controlDirectory.path.count <= longestControlDirectory,
           controlDirectory.path.rangeOfCharacter(from: unusableInControlPath) == nil {
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlDirectory.path)/%C",
                "-o", "ControlPersist=\(Int(keepConnection))"
            ]
        }
        // After "--" nothing is read as an option, whatever the alias looks like.
        return arguments + ["--", alias, "/bin/sh"]
    }

    /// What a script that ran to its end left behind.
    public struct Reply: Sendable, Equatable {
        /// The script's standard output, byte for byte.
        public var output: Data
        /// The script's error output, without the line it reported back with.
        public var errorOutput: String
        /// What the script reported after the marker, such as "ok" or "exit 3".
        public var status: String
    }

    /// Runs a script and waits for it.
    ///
    /// - Parameters:
    ///   - timeout: How long the script itself may take. The time to connect comes on top.
    ///   - mayHang: Whether the script runs a program of the user's, which may take too long without the
    ///     machine being at fault. Its timing out then says nothing about the machine.
    public func run(_ script: String, timeout: TimeInterval, mayHang: Bool = false) throws(RemoteShellError) -> Reply {
        if let tripped = breaker?.tripped {
            throw tripped
        }
        do {
            return try send(script, timeout: timeout)
        } catch {
            switch error {
            case .unreachable: breaker?.tripped = error
            case .timedOut where !mayHang: breaker?.tripped = error
            case .timedOut, .broken: break
            }
            throw error
        }
    }

    private func send(_ script: String, timeout: TimeInterval) throws(RemoteShellError) -> Reply {
        let result: CommandResult
        do {
            result = try runner.run(
                executable,
                arguments: arguments,
                input: Data((Self.preamble + script + "\n").utf8),
                timeout: timeout + Self.connectTimeout
            )
        } catch {
            switch error {
            case let .notStarted(reason): throw .unreachable("ssh could not be started: \(reason)")
            case .timedOut: throw .timedOut(after: timeout + Self.connectTimeout)
            }
        }
        // ssh ends its own messages with a carriage return and a line feed, which Swift reads as one character.
        var lines = result.errorOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard let last = lines.last, last.hasPrefix(Self.marker) else {
            let said = lines.last { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces)
            // ssh exits with 255 when it is the connection that failed, and says why.
            if result.exitCode == 255 {
                throw .unreachable(said ?? "the connection failed")
            }
            throw .broken(said.map { "the script did not finish: \($0)" } ?? "the script did not finish")
        }
        lines.removeLast()
        // The report is written on a line of its own, whatever came before it.
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard let start = result.outputData.range(of: Data(Self.begin.utf8)) else {
            throw .broken("the script did not start")
        }
        return Reply(
            output: result.outputData[start.upperBound...],
            errorOutput: lines.joined(separator: "\n"),
            status: String(last.dropFirst(Self.marker.count))
        )
    }
}
