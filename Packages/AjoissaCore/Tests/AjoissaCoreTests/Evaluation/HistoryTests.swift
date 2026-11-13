import AjoissaCore
import XCTest

final class HistoryTests: XCTestCase {
    private var directory: URL!
    private var file: HistoryFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ajoissa-history-\(UUID().uuidString)")
        // The folder is not created here: saving has to create it.
        file = HistoryFile(url: directory.appending(path: "nested/history.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileIsAnEmptyHistory() throws {
        XCTAssertEqual(try file.load(), History())
    }

    func testSavedHistoryComesBackTheSame() throws {
        let record = JobRecord(
            watchingSince: TestClock.date("2026-11-12 12:00"),
            timetable: Timetable(calendarRules: [.init(minute: 0, hour: 2, weekday: 1)], interval: 900),
            lastObservedAt: TestClock.date("2026-11-14 02:05"),
            lastRunCount: 4,
            lastRun: TestClock.date("2026-11-14 02:01"),
            unreadableSince: TestClock.date("2026-11-14 01:00"),
            unavailableSince: TestClock.date("2026-11-13 09:00"),
            openRun: TestClock.date("2026-11-14 02:00"),
            openRunGraceFrom: TestClock.date("2026-11-14 07:00"),
            intervalFrom: TestClock.date("2026-11-14 01:45"),
            stateBeforeUnreadable: .ok,
            state: .missed,
            reason: "there is no sign of the run that was due at 2026-11-14 02:00",
            stateSince: TestClock.date("2026-11-14 02:31"),
            lastEvaluatedAt: TestClock.date("2026-11-14 02:32"),
            transitions: [JobRecord.Transition(date: TestClock.date("2026-11-14 02:31"), state: .missed, reason: "no sign")]
        )
        let history = History(jobs: ["nightly": record, "empty": JobRecord(watchingSince: TestClock.date("2026-11-14 00:00"))])

        try file.save(history)

        XCTAssertEqual(try file.load(), history)
    }

    func testSavingReplacesTheFile() throws {
        try file.save(History(jobs: ["a": JobRecord(watchingSince: TestClock.date("2026-11-14 00:00"))]))
        try file.save(History(jobs: ["b": JobRecord(watchingSince: TestClock.date("2026-11-14 00:00"))]))

        XCTAssertEqual(try file.load().jobs.keys.sorted(), ["b"])
    }

    func testFileIsWrittenForAPersonToRead() throws {
        try file.save(History(jobs: ["a": JobRecord(watchingSince: TestClock.date("2026-11-14 02:00"))]))

        let text = try String(contentsOf: file.url, encoding: .utf8)

        XCTAssertTrue(text.contains("\"watchingSince\" : \"2026-11-14T02:00:00Z\""), text)
        XCTAssertTrue(text.contains("\"state\" : \"waiting\""), text)
    }

    func testFileThatIsNotAHistoryIsAnErrorAndIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nonsense".utf8).write(to: file.url)

        XCTAssertThrowsError(try file.load()) { error in
            XCTAssertEqual(error as? HistoryError, .unreadable(path: file.url.path, reason: "it is not a valid history file"))
        }
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "nonsense")
    }

    func testHistoryFromAnotherVersionIsRefused() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{ "version": 2, "jobs": {} }"#.utf8).write(to: file.url)

        XCTAssertThrowsError(try file.load()) { error in
            XCTAssertEqual(
                error as? HistoryError,
                .unreadable(path: file.url.path, reason: "it is version 2, and this Ajoissa reads version 1")
            )
        }
    }

    func testSavingWhereItCannotBeWrittenIsAnError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appending(path: "nested"))

        XCTAssertThrowsError(try file.save(History())) { error in
            guard case let .unwritable(path, _) = error as? HistoryError else {
                return XCTFail("Expected unwritable, got \(error)")
            }
            XCTAssertEqual(path, file.url.path)
        }
    }

    func testKeepOnlyDropsJobsThatAreGone() {
        let record = JobRecord(watchingSince: TestClock.date("2026-11-14 00:00"))
        var history = History(jobs: ["a": record, "b": record, "c": record])

        history.keepOnly(jobIDs: ["c", "a", "new"])

        XCTAssertEqual(history.jobs.keys.sorted(), ["a", "c"])
    }

    func testLocation() {
        let home = URL(fileURLWithPath: "/Users/example")

        XCTAssertEqual(
            HistoryFile(environment: [:], homeDirectory: home).url.path,
            "/Users/example/Library/Application Support/Ajoissa/history.json"
        )
        XCTAssertEqual(HistoryFile(environment: ["AJOISSA_HISTORY": "/tmp/h.json"], homeDirectory: home).url.path, "/tmp/h.json")
        XCTAssertEqual(
            HistoryFile(environment: ["AJOISSA_HISTORY": ""], homeDirectory: home).url.path,
            "/Users/example/Library/Application Support/Ajoissa/history.json"
        )
    }
}
