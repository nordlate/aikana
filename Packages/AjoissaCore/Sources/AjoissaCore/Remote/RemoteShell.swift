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
    /// What every script starts with: messages of tools are compared, so they must not be translated.
    static let preamble = "LC_ALL=C\nexport LC_ALL\n"

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

    /// The arguments `ssh` is run with. This is the whole of what Ajoissa adds to the user's own settings.
    static func sshArguments(alias: String, controlDirectory: URL?) -> [String] {
        var arguments = [
            // No terminal, and never a question: a key that needs a passphrase typed, or a host that is not
            // known yet, is a failure to connect, not a prompt nobody sees.
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Int(connectTimeout))"
        ]
        if let controlDirectory, controlDirectory.path.count <= longestControlDirectory {
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
    /// - Parameter timeout: How long the script itself may take. The time to connect comes on top.
    public func run(_ script: String, timeout: TimeInterval) throws(RemoteShellError) -> Reply {
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
        return Reply(
            output: result.outputData,
            errorOutput: lines.joined(separator: "\n"),
            status: String(last.dropFirst(Self.marker.count))
        )
    }
}
