@testable import AjoissaCore
import XCTest

final class RemoteHostRunTests: RemoteHostTestCase {
    private let time = Date(timeIntervalSince1970: 1_763_085_600)

    // MARK: - Running

    func testACommandGetsItsArgumentsAsTheyAre() throws {
        try inEveryShell { host in
            let result = try host.run(["/usr/bin/printf", "%s|"] + RemoteShellTests.hostile.filter { !$0.hasPrefix("-") }, timeout: 5)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.output, RemoteShellTests.hostile.filter { !$0.hasPrefix("-") }.map { "\($0)|" }.joined())
        }
    }

    func testACommandsExitCodeAndOutput() throws {
        try inEveryShell { host in
            let result = try host.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], timeout: 5)
            XCTAssertEqual(result, CommandResult(exitCode: 3, output: "out\n", errorOutput: "err"))
            XCTAssertEqual(try host.run(["/usr/bin/true"], timeout: 5).exitCode, 0)
            XCTAssertEqual(try host.run(["/bin/sh", "-c", "exit 255"], timeout: 5).exitCode, 255)
        }
    }

    func testACommandDoesNotReadTheScriptItCameWith() throws {
        try inEveryShell { host in
            // `cat` would swallow the rest of the script, and the report with it, if it were given the input.
            XCTAssertEqual(try host.run(["/bin/cat"], timeout: 5), CommandResult(exitCode: 0))
        }
    }

    func testAProgramInTheHomeFolder() throws {
        let tool = try write("bin/check.sh", "#!/bin/sh\necho \"checked $1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        try inEveryShell { host in
            XCTAssertEqual(try host.run(["~/bin/check.sh", "~/not-expanded"], timeout: 5).output, "checked ~/not-expanded\n")
        }
    }

    func testAProgramThatIsNotThereCouldNotBeStarted() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "folder"), withIntermediateDirectories: true)
        let notExecutable = try write("plain.txt")
        try inEveryShell { host in
            for program in ["\(root.path)/no-such-program", "\(root.path)/folder", notExecutable] {
                XCTAssertThrowsError(try host.run([program], timeout: 5), program) { error in
                    XCTAssertEqual(error as? CommandError, .notStarted(reason: "there is no such program on studio"))
                }
            }
        }
    }

    func testACommandThatHangsTimesOut() throws {
        let host = try host("/bin/sh")
        let started = Date()
        XCTAssertThrowsError(try host.run(["/bin/sleep", "60"], timeout: 1)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(after: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testAnArgumentWithALineBreakIsRefused() throws {
        let host = try host("/bin/sh")
        XCTAssertThrowsError(try host.run(["/bin/echo", "two\nlines"], timeout: 5)) { error in
            XCTAssertEqual(error as? CommandError, .notStarted(reason: "an argument has a line break in it"))
        }
        XCTAssertThrowsError(try host.files(matching: "/tmp/a\nb")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "/tmp/a\nb has a line break in it")
        }
    }

    // MARK: - A machine that stops answering

    func testAMachineThatDoesNotAnswerIsNotTakenForAMissingFile() throws {
        let facts = RemoteFacts(system: "Darwin", userID: 501, home: "/Users/example", now: time)
        let dead = RemoteShell(runner: RecordingRunner(answer: CommandResult(exitCode: 255, errorOutput: "ssh: connect to host studio port 22: Connection refused\n")), executable: "/usr/bin/ssh", arguments: [])
        let host = RemoteHost(name: "studio", shell: dead, facts: facts)

        XCTAssertThrowsError(try host.files(matching: "~/x/*.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "~/x/*.md could not be looked at: studio did not answer: ssh: connect to host studio port 22: Connection refused")
        }
        XCTAssertThrowsError(try host.file(at: "~/x.log"))
        XCTAssertThrowsError(try host.read("~/x.log", range: 0..<5))
        XCTAssertThrowsError(try host.run(["/usr/bin/true"], timeout: 5)) { error in
            XCTAssertEqual(error as? CommandError, .notStarted(reason: "studio did not answer: ssh: connect to host studio port 22: Connection refused"))
        }
        XCTAssertEqual(host.contents(ofFileAt: "/Library/LaunchDaemons/x.plist"), .unreadable)
        XCTAssertNil(host.plistNames(in: "/Library/LaunchDaemons"))
    }

    // MARK: - launchd's files

    func testPlistNamesAndContents() throws {
        try write("agents/com.example.b.plist", "b")
        try write("agents/com.example.a.plist", "a")
        try write("agents/notes.txt")
        try write("empty/keep.txt")
        try write("locked/x.plist")
        try lock("locked")
        try inEveryShell { host in
            XCTAssertEqual(host.plistNames(in: "\(root.path)/agents"), ["com.example.a.plist", "com.example.b.plist"])
            XCTAssertEqual(host.plistNames(in: "\(root.path)/empty"), [])
            XCTAssertEqual(host.plistNames(in: "\(root.path)/nowhere"), [])
            XCTAssertNil(host.plistNames(in: "\(root.path)/locked"))
            XCTAssertEqual(host.contents(ofFileAt: "\(root.path)/agents/com.example.a.plist"), .data(Data("a".utf8)))
            XCTAssertEqual(host.contents(ofFileAt: "\(root.path)/agents/none.plist"), .missing)
        }
    }

    func testAnEmptyOrUnreadableFile() throws {
        try write("agents/empty.plist", "")
        try write("agents/secret.plist")
        try lock("agents/secret.plist")
        try inEveryShell { host in
            XCTAssertEqual(host.contents(ofFileAt: "\(root.path)/agents/empty.plist"), .data(Data()))
            XCTAssertEqual(host.contents(ofFileAt: "\(root.path)/agents/secret.plist"), .unreadable)
        }
    }
}
