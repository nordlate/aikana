@testable import AikanaCore
import XCTest

final class RemoteShellTests: RemoteHostTestCase {
    /// Values no shell must be allowed to read anything into.
    static let hostile = [
        "plain",
        "with space",
        "it's",
        "''",
        "'; echo pwned; '",
        "$(echo pwned)",
        "`echo pwned`",
        "$HOME",
        "a\"b",
        "back\\slash",
        "trailing\\",
        "semi;colon && and || or | pipe > out < in",
        "*",
        "~",
        "-n",
        "tab\there",
        "päivä ☀️",
        "#comment",
        "!history",
        "%s%d"
    ]

    // MARK: - Quoting

    func testAQuotedValueReachesAProgramExactlyAsItIs() throws {
        for shellPath in Self.shells {
            for value in Self.hostile {
                let script = "printf '%s' \(ShellQuoting.quote(value))\nprintf 'aikana:ok\\n' >&2"
                let reply = try shell(shellPath).run(script, timeout: 5)
                XCTAssertEqual(String(data: reply.output, encoding: .utf8), value, "\(shellPath): \(value)")
                XCTAssertEqual(reply.status, "ok")
                XCTAssertEqual(reply.errorOutput, "", "\(shellPath): \(value)")
            }
        }
    }

    func testQuoting() {
        XCTAssertEqual(ShellQuoting.quote("plain"), "'plain'")
        XCTAssertEqual(ShellQuoting.quote(""), "''")
        XCTAssertEqual(ShellQuoting.quote("it's"), "'it'\\''s'")
    }

    func testAValueWithALineBreakCannotBeQuoted() {
        XCTAssertTrue(ShellQuoting.isQuotable("one line; with $(things)"))
        XCTAssertFalse(ShellQuoting.isQuotable("two\nlines"))
        XCTAssertFalse(ShellQuoting.isQuotable("carriage\rreturn"))
        XCTAssertFalse(ShellQuoting.isQuotable("nul\0"))
    }

    // MARK: - What ssh is run with

    func testSSHArguments() {
        let arguments = RemoteShell.sshArguments(alias: "studio-mac", controlDirectory: URL(fileURLWithPath: "/Users/example/Library/Caches/Aikana/cm"))
        XCTAssertEqual(arguments, [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/Users/example/Library/Caches/Aikana/cm/%C",
            "-o", "ControlPersist=600",
            "--", "studio-mac", "/bin/sh"
        ])
    }

    func testAControlFolderTooLongForASocketIsLeftOut() {
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 60) + "/cm")
        XCTAssertEqual(RemoteShell.sshArguments(alias: "tower", controlDirectory: long), Self.plainArguments)
        XCTAssertEqual(RemoteShell.sshArguments(alias: "tower", controlDirectory: nil).suffix(3), ["--", "tower", "/bin/sh"])
    }

    private static let plainArguments = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        "--", "tower", "/bin/sh"
    ]

    func testAControlFolderSSHWouldMisreadIsLeftOut() {
        for path in ["/Users/first last/cm", "/Users/100%/cm", "/Users/o'brien/cm", "/Users/a\"b/cm", "/Users/back\\slash/cm"] {
            XCTAssertEqual(RemoteShell.sshArguments(alias: "tower", controlDirectory: URL(fileURLWithPath: path)), Self.plainArguments, path)
        }
    }

    func testTheScriptGoesToSSHOnItsInputAndNeverOnItsCommandLine() throws {
        let runner = RecordingRunner(answer: CommandResult(exitCode: 0, output: "aikana:begin\nout", errorOutput: "\naikana:ok\n"))
        let shell = RemoteShell.ssh(alias: "tower", runner: runner, controlDirectory: nil)

        let reply = try shell.run("echo 'a value'", timeout: 20)

        XCTAssertEqual(reply, RemoteShell.Reply(output: Data("out".utf8), errorOutput: "", status: "ok"))
        XCTAssertEqual(runner.executable, "/usr/bin/ssh")
        XCTAssertEqual(runner.arguments, Self.plainArguments)
        XCTAssertEqual(runner.input, "printf 'aikana:begin\\n'\nLC_ALL=C\nexport LC_ALL\necho 'a value'\n")
        XCTAssertEqual(runner.timeout, 30)
        XCTAssertEqual(RemoteHost.readTimeout, 15)
    }

    // MARK: - Answers

    func testWhatTheScriptWroteBeforeItsReportIsKept() throws {
        let reply = try shell("/bin/sh").run("echo out; echo warning >&2; printf 'aikana:exit 3\\n' >&2", timeout: 5)
        XCTAssertEqual(reply, RemoteShell.Reply(output: Data("out\n".utf8), errorOutput: "warning", status: "exit 3"))
    }

    func testWhatTheUsersShellWritesBeforeTheScriptStartsIsDropped() throws {
        // As a line in the remote user's startup files would: written before /bin/sh reads the script.
        let noisy = RemoteShell(runner: ProcessCommandRunner(), executable: "/bin/sh", arguments: ["-c", "echo 'Welcome to studio'; echo 'motd' >&2; exec /bin/sh"])

        XCTAssertEqual(try noisy.run("printf 'payload'; printf '\\naikana:ok\\n' >&2", timeout: 5).output, Data("payload".utf8))
        XCTAssertEqual(try RemoteHost.probe(noisy).userID, getuid())
    }

    func testOutputWithoutAStartIsNotUsed() {
        let runner = RecordingRunner(answer: CommandResult(exitCode: 0, output: "something", errorOutput: "aikana:ok\n"))
        XCTAssertThrowsError(try RemoteShell(runner: runner, executable: "/bin/sh", arguments: []).run("true", timeout: 5)) { error in
            XCTAssertEqual(error as? RemoteShellError, .broken("the script did not start"))
        }
    }

    // MARK: - A machine that stops answering during a look

    func testAfterAMachineStopsAnsweringTheRestOfTheLookDoesNotWaitForIt() {
        let runner = CountingRunner(.success(CommandResult(exitCode: 255, errorOutput: "ssh: connect to host tower port 22: Operation timed out\n")))
        let shell = RemoteShell.ssh(alias: "tower", runner: runner, controlDirectory: nil).forOneLook()

        for _ in 1...3 {
            XCTAssertThrowsError(try shell.run("true", timeout: 5)) { error in
                XCTAssertEqual(error as? RemoteShellError, .unreachable("ssh: connect to host tower port 22: Operation timed out"))
            }
        }
        XCTAssertEqual(runner.count, 1)
        // The next look tries again.
        XCTAssertThrowsError(try RemoteShell.ssh(alias: "tower", runner: runner, controlDirectory: nil).forOneLook().run("true", timeout: 5))
        XCTAssertEqual(runner.count, 2)
    }

    func testAScriptThatTimesOutEndsTheLookForItsMachineUnlessItRanTheUsersProgram() {
        let runner = CountingRunner(.failure(.timedOut(after: 15)))
        let shell = RemoteShell(runner: runner, executable: "/bin/sh", arguments: []).forOneLook()

        XCTAssertThrowsError(try shell.run("sleep 60", timeout: 5, mayHang: true))
        XCTAssertThrowsError(try shell.run("sleep 60", timeout: 5, mayHang: true))
        XCTAssertEqual(runner.count, 2)

        XCTAssertThrowsError(try shell.run("true", timeout: 5))
        XCTAssertThrowsError(try shell.run("true", timeout: 5))
        XCTAssertEqual(runner.count, 3)
    }

    func testAConnectionThatFailsIsUnreachableWithWhatSSHSaid() {
        let runner = RecordingRunner(answer: CommandResult(
            exitCode: 255,
            errorOutput: "ssh: connect to host tower port 22: Operation timed out\r\n"
        ))
        XCTAssertThrowsError(try RemoteShell.ssh(alias: "tower", runner: runner, controlDirectory: nil).run("true", timeout: 5)) { error in
            XCTAssertEqual(error as? RemoteShellError, .unreachable("ssh: connect to host tower port 22: Operation timed out"))
        }
    }

    func testAScriptThatDoesNotReportIsBroken() {
        XCTAssertThrowsError(try shell("/bin/sh").run("echo half; exit 3", timeout: 5)) { error in
            XCTAssertEqual(error as? RemoteShellError, .broken("the script did not finish"))
        }
        XCTAssertThrowsError(try shell("/bin/sh").run("echo no >&2; exit 1", timeout: 5)) { error in
            XCTAssertEqual(error as? RemoteShellError, .broken("the script did not finish: no"))
        }
    }

    func testAScriptThatExitsWith255AfterReportingIsNotMistakenForAFailedConnection() throws {
        XCTAssertEqual(try shell("/bin/sh").run("printf 'aikana:exit 255\\n' >&2; exit 255", timeout: 5).status, "exit 255")
    }

    func testAScriptThatTakesTooLongIsStopped() {
        let shell = RemoteShell(runner: RecordingRunner(error: .timedOut(after: 15)), executable: "/bin/sh", arguments: [])
        XCTAssertThrowsError(try shell.run("sleep 60", timeout: 5)) { error in
            XCTAssertEqual(error as? RemoteShellError, .timedOut(after: 15))
        }
    }

    func testSSHThatCannotBeStartedIsUnreachable() {
        let shell = RemoteShell(runner: ProcessCommandRunner(), executable: root.appending(path: "no-ssh").path, arguments: [])
        XCTAssertThrowsError(try shell.run("true", timeout: 5)) { error in
            guard case let .unreachable(reason) = error as? RemoteShellError else {
                return XCTFail("Expected unreachable, got \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("ssh could not be started: "), reason)
        }
    }

    // MARK: - The probe

    func testTheProbeOnThisMac() throws {
        for shellPath in Self.shells {
            let facts = try RemoteHost.probe(shell(shellPath))
            XCTAssertEqual(facts.system, "Darwin")
            XCTAssertTrue(facts.isMac)
            XCTAssertEqual(facts.userID, getuid())
            XCTAssertEqual(facts.home, NSHomeDirectory())
            XCTAssertEqual(facts.now.timeIntervalSinceNow, 0, accuracy: 5)
            XCTAssertEqual(facts.bootedAt?.timeIntervalSince1970 ?? 0, SystemUptime.bootedAt()?.timeIntervalSince1970 ?? -1, accuracy: 1)
            XCTAssertEqual(facts.awakeSince?.timeIntervalSince1970 ?? 0, SystemUptime.awakeSince()?.timeIntervalSince1970 ?? -1, accuracy: 1)
            XCTAssertEqual(facts.timeZone, TimeZone.current)
        }
    }

    func testProbeOutput() throws {
        let mac = try XCTUnwrap(RemoteFacts(probeOutput: """
            Darwin
            501
            /Users/example
            1763085600
            { sec = 1763000000, usec = 123456 } Thu Nov 13 04:13:20 2026
            { sec = 1763080000, usec = 0 } Fri Nov 14 02:26:40 2026
            /var/db/timezone/zoneinfo/Europe/Helsinki

            """))
        XCTAssertEqual(mac, RemoteFacts(
            system: "Darwin",
            userID: 501,
            home: "/Users/example",
            now: Date(timeIntervalSince1970: 1_763_085_600),
            bootedAt: Date(timeIntervalSince1970: 1_763_000_000),
            awakeSince: Date(timeIntervalSince1970: 1_763_080_000),
            timeZone: TimeZone(identifier: "Europe/Helsinki")
        ))

        let linux = try XCTUnwrap(RemoteFacts(probeOutput: "Linux\n1000\n/home/example\n1763085600\n\n\n/usr/share/zoneinfo/Etc/UTC\n"))
        XCTAssertFalse(linux.isMac)
        XCTAssertNil(linux.bootedAt)
        XCTAssertNil(linux.awakeSince)
        XCTAssertEqual(linux.timeZone, TimeZone(identifier: "Etc/UTC"))

        // A Mac that has never slept reports a wake time of zero: it has been awake since it started.
        let neverSlept = try XCTUnwrap(RemoteFacts(probeOutput: "Darwin\n501\n/Users/example\n1763085600\n{ sec = 1763000000, usec = 0 } x\n{ sec = 0, usec = 0 } x\n\n"))
        XCTAssertEqual(neverSlept.awakeSince, Date(timeIntervalSince1970: 1_763_000_000))
        XCTAssertNil(neverSlept.timeZone)
    }

    func testProbeOutputThatIsNotWhatWasAskedFor() {
        for output in ["", "Darwin\n501\n", "Darwin\nroot\n/Users/example\n1\n\n\n\n", "Darwin\n501\nhome\n1\n\n\n\n", "\n501\n/h\n1\n\n\n\n", "Welcome!\nDarwin\n501\n/h\nx\n\n\n"] {
            XCTAssertNil(RemoteFacts(probeOutput: output), output)
        }
    }
}

/// Stands in for `ssh`: gives one answer and counts how often it was asked.
final class CountingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<CommandResult, CommandError>
    private var calls = 0

    init(_ result: Result<CommandResult, CommandError>) {
        self.result = result
    }

    var count: Int { lock.withLock { calls } }

    func run(_ executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws(CommandError) -> CommandResult {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

/// Stands in for `ssh`: remembers how it was called and gives one answer.
final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<CommandResult, CommandError>
    private var call: Call?

    private struct Call {
        var executable: String
        var arguments: [String]
        var input: String?
        var timeout: TimeInterval
    }

    init(answer: CommandResult) {
        result = .success(answer)
    }

    init(error: CommandError) {
        result = .failure(error)
    }

    var executable: String? { lock.withLock { call?.executable } }
    var arguments: [String]? { lock.withLock { call?.arguments } }
    var input: String? { lock.withLock { call?.input } }
    var timeout: TimeInterval? { lock.withLock { call?.timeout } }

    func run(_ executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws(CommandError) -> CommandResult {
        lock.withLock {
            call = Call(executable: executable, arguments: arguments, input: input.flatMap { String(data: $0, encoding: .utf8) }, timeout: timeout)
        }
        return try result.get()
    }
}
