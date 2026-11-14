import AikanaCore
import XCTest

final class LocalHostTests: XCTestCase {
    private var home: URL!
    private var runner: FakeCommandRunner!
    private var host: LocalHost!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "aikana-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "reports/nested"), withIntermediateDirectories: true)
        runner = FakeCommandRunner()
        host = LocalHost(homeDirectory: home, runner: runner)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "reports").path)
        try FileManager.default.removeItem(at: home)
    }

    // MARK: - Files

    func testPatternMatchesRegularFilesOnly() throws {
        try write("reports/a.md", "one")
        try write("reports/b.md", "three")
        try write("reports/c.txt", "x")
        try FileManager.default.createDirectory(at: home.appending(path: "reports/folder.md"), withIntermediateDirectories: true)

        let files = try host.files(matching: "~/reports/*.md").sorted { $0.path < $1.path }

        XCTAssertEqual(files.map(\.path), [home.appending(path: "reports/a.md").path, home.appending(path: "reports/b.md").path])
        XCTAssertEqual(files.map(\.size), [3, 5])
    }

    func testModificationTimeIsReported() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try write("reports/a.md", "x")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: home.appending(path: "reports/a.md").path)

        XCTAssertEqual(try host.files(matching: "~/reports/a.md").first?.modified, stamp)
        XCTAssertEqual(try host.file(at: "~/reports/a.md")?.modified, stamp)
    }

    func testAbsolutePathsAndQuestionMarksAndBrackets() throws {
        try write("reports/log1.txt", "")
        try write("reports/log2.txt", "")
        try write("reports/log10.txt", "")
        let folder = home.appending(path: "reports").path

        XCTAssertEqual(try host.files(matching: "\(folder)/log?.txt").count, 2)
        XCTAssertEqual(try host.files(matching: "\(folder)/log[2-9].txt").count, 1)
        XCTAssertEqual(try host.files(matching: "\(folder)/*/*.txt").count, 0)
    }

    func testNoMatchIsAnEmptyListNotAnError() throws {
        XCTAssertEqual(try host.files(matching: "~/reports/*.pdf"), [])
        XCTAssertEqual(try host.files(matching: "~/reports/missing.md"), [])
        XCTAssertEqual(try host.files(matching: "/nonexistent/folder/*.md"), [])
        XCTAssertNil(try host.file(at: "~/reports/missing.md"))
        XCTAssertNil(try host.file(at: "~/reports/nested"))
    }

    func testFolderThatCannotBeReadIsAnError() throws {
        try write("reports/a.md", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appending(path: "reports").path)

        XCTAssertThrowsError(try host.files(matching: "~/reports/*.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "~/reports/*.md could not be searched: a folder on the way could not be read")
        }
        XCTAssertThrowsError(try host.files(matching: "~/reports/a.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "~/reports/a.md could not be searched: a folder on the way could not be read")
        }
        XCTAssertThrowsError(try host.file(at: "~/reports/a.md")) { error in
            XCTAssertTrue((error as? HostAccessError)?.message.hasPrefix("~/reports/a.md could not be read:") ?? false, "\(error)")
        }
    }

    /// `*/a.md` leads through every folder in the home directory. One of them cannot be entered, and the file
    /// may be in it, so "nothing matches" would be a guess.
    func testFolderThatCannotBeEnteredHalfwayDownThePathIsAnError() throws {
        try write("reports/a.md", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appending(path: "reports").path)

        XCTAssertThrowsError(try host.files(matching: "~/*/a.md")) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "~/*/a.md could not be searched: a folder on the way could not be read")
        }
        XCTAssertThrowsError(try host.files(matching: "~/*/nested/*.md"))
    }

    func testReadableFoldersWithNoMatchAreStillJustNoMatch() throws {
        try write("reports/a.md", "x")

        XCTAssertEqual(try host.files(matching: "~/*/b.md"), [])
        XCTAssertEqual(try host.files(matching: "~/*/nested/*.md"), [])
    }

    // MARK: - Links and hidden files

    /// A log is often a link to the file of the day. What counts is the file it points at.
    func testLinkIsSeenAsTheFileItPointsAt() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try write("reports/2026-11-14.log", "today's log, 23 bytes..")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: home.appending(path: "reports/2026-11-14.log").path)
        try FileManager.default.createSymbolicLink(
            atPath: home.appending(path: "reports/current.log").path,
            withDestinationPath: home.appending(path: "reports/2026-11-14.log").path
        )

        let link = try XCTUnwrap(try host.file(at: "~/reports/current.log"))
        let target = try XCTUnwrap(try host.file(at: "~/reports/2026-11-14.log"))

        XCTAssertEqual(link.size, 23)
        XCTAssertEqual(link.modified, stamp)
        XCTAssertEqual(link.identity, target.identity)
        XCTAssertEqual(try host.files(matching: "~/reports/current.*").map(\.size), [23])
        XCTAssertEqual(try text("~/reports/current.log", 8..<11), "log")
    }

    func testLinkThatPointsNowhereIsNoFile() throws {
        try FileManager.default.createSymbolicLink(
            atPath: home.appending(path: "reports/dangling.log").path,
            withDestinationPath: home.appending(path: "reports/gone.log").path
        )

        XCTAssertNil(try host.file(at: "~/reports/dangling.log"))
        XCTAssertEqual(try host.files(matching: "~/reports/*.log"), [])
    }

    func testReplacedFileHasAnotherIdentityAndARewrittenOneKeepsIts() throws {
        try write("reports/job.log", "first")
        let first = try XCTUnwrap(try host.file(at: "~/reports/job.log")?.identity)

        let handle = try FileHandle(forWritingTo: home.appending(path: "reports/job.log"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("rewritten in place".utf8))
        try handle.close()
        XCTAssertEqual(try host.file(at: "~/reports/job.log")?.identity, first)

        try FileManager.default.moveItem(at: home.appending(path: "reports/job.log"), to: home.appending(path: "reports/job.log.1"))
        try write("reports/job.log", "a new file")
        XCTAssertNotEqual(try host.file(at: "~/reports/job.log")?.identity, first)
    }

    /// As in a shell, `*` does not match a name that starts with a dot.
    func testStarDoesNotMatchHiddenFiles() throws {
        try write("reports/.hidden.md", "x")
        try write("reports/seen.md", "x")

        XCTAssertEqual(try host.files(matching: "~/reports/*.md").count, 1)
        XCTAssertEqual(try host.files(matching: "~/reports/.*.md").count, 1)
    }

    func testPathWithSpacesIsOnePath() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "My Reports"), withIntermediateDirectories: true)
        try write("My Reports/the report.md", "x")

        XCTAssertEqual(try host.files(matching: "~/My Reports/*.md").count, 1)
        XCTAssertNotNil(try host.file(at: "~/My Reports/the report.md"))
    }

    // MARK: - Reading

    func testReadARange() throws {
        try write("reports/job.log", "0123456789")

        XCTAssertEqual(try text("~/reports/job.log", 0..<10), "0123456789")
        XCTAssertEqual(try text("~/reports/job.log", 4..<7), "456")
        XCTAssertEqual(try text("~/reports/job.log", 8..<100), "89")
        XCTAssertEqual(try text("~/reports/job.log", 10..<20), "")
        XCTAssertEqual(try text("~/reports/job.log", 99..<120), "")
        XCTAssertEqual(try text("~/reports/job.log", 5..<5), "")
    }

    func testReadingAMissingFileIsEmptyAndAnUnreadableOneIsAnError() throws {
        XCTAssertEqual(try text("~/reports/missing.log", 0..<100), "")

        try write("reports/job.log", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appending(path: "reports").path)
        XCTAssertThrowsError(try host.read("~/reports/job.log", range: 0..<100))
    }

    // MARK: - Commands

    func testProgramInTheHomeDirectoryIsExpandedAndArgumentsAreLeftAlone() throws {
        runner.answer("~/untouched", with: .success(CommandResult(exitCode: 3, output: "out")))

        let result = try host.run(["~/bin/check", "--path", "~/untouched"], timeout: 12)

        XCTAssertEqual(result, CommandResult(exitCode: 3, output: "out"))
        XCTAssertEqual(runner.calls, [[home.appending(path: "bin/check").path, "--path", "~/untouched"]])
    }

    func testRunningNothingIsAnError() {
        XCTAssertThrowsError(try host.run([], timeout: 1)) { error in
            XCTAssertEqual(error as? CommandError, .notStarted(reason: "no program was given"))
        }
    }

    func testRealProgramRuns() throws {
        let real = LocalHost(homeDirectory: home, runner: ProcessCommandRunner())

        XCTAssertEqual(try real.run(["/bin/echo", "hello"], timeout: 10), CommandResult(exitCode: 0, output: "hello\n"))
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: home.appending(path: relativePath))
    }

    private func text(_ path: String, _ range: Range<Int64>) throws -> String {
        String(data: try host.read(path, range: range), encoding: .utf8) ?? ""
    }
}
