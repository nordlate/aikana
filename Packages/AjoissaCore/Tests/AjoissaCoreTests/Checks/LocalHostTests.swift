import AjoissaCore
import XCTest

final class LocalHostTests: XCTestCase {
    private var home: URL!
    private var runner: FakeCommandRunner!
    private var host: LocalHost!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "ajoissa-host-\(UUID().uuidString)")
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
            XCTAssertTrue((error as? HostAccessError)?.message.hasPrefix("~/reports/a.md could not be read:") ?? false, "\(error)")
        }
        XCTAssertThrowsError(try host.file(at: "~/reports/a.md"))
    }

    // MARK: - Reading

    func testReadFromAnOffset() throws {
        try write("reports/job.log", "0123456789")

        XCTAssertEqual(try text("~/reports/job.log", from: 0, limit: 100), "0123456789")
        XCTAssertEqual(try text("~/reports/job.log", from: 4, limit: 100), "456789")
        XCTAssertEqual(try text("~/reports/job.log", from: 10, limit: 100), "")
        XCTAssertEqual(try text("~/reports/job.log", from: 99, limit: 100), "")
    }

    func testReadKeepsTheEndWhenThereIsMoreThanTheLimit() throws {
        try write("reports/job.log", "0123456789")

        XCTAssertEqual(try text("~/reports/job.log", from: 0, limit: 3), "789")
        XCTAssertEqual(try text("~/reports/job.log", from: 8, limit: 3), "89")
    }

    func testReadingAMissingFileIsEmptyAndAnUnreadableOneIsAnError() throws {
        XCTAssertEqual(try text("~/reports/missing.log", from: 0, limit: 100), "")

        try write("reports/job.log", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appending(path: "reports").path)
        XCTAssertThrowsError(try host.read("~/reports/job.log", from: 0, limit: 100))
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

    private func text(_ path: String, from offset: Int64, limit: Int) throws -> String {
        String(data: try host.read(path, from: offset, limit: limit), encoding: .utf8) ?? ""
    }
}
