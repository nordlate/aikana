import AjoissaCore
import XCTest

final class LogTailTests: XCTestCase {
    private let host = FakeHost()
    private let path = "/var/log/example.log"

    func testAShortLogIsShownWhole() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: "one\ntwo\n")
        XCTAssertEqual(try LogTail.read(path, on: host), "one\ntwo\n")
    }

    func testALongLogIsShownFromTheFirstWholeLineWithinTheLimit() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: "first line\nsecond line\nthird line\n")
        XCTAssertEqual(try LogTail.read(path, on: host, limit: 20), "third line\n")
    }

    func testALongLogWithNoLineBreakIsShownCut() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: "abcdefghij")
        XCTAssertEqual(try LogTail.read(path, on: host, limit: 4), "ghij")
    }

    func testALineThatStartsExactlyAtTheLimitIsKept() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: "aaaa\nbbbb\ncccc\n")
        XCTAssertEqual(try LogTail.read(path, on: host, limit: 10), "bbbb\ncccc\n")
    }

    func testALastLineLongerThanTheLimitIsShownCut() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: "short\n" + String(repeating: "x", count: 30) + "\n")
        XCTAssertEqual(try LogTail.read(path, on: host, limit: 20), String(repeating: "x", count: 19) + "\n")
    }

    func testOnlyTheEndIsRead() throws {
        host.put(path, modified: "2026-11-14 02:00", contents: String(repeating: "x", count: 100))
        _ = try LogTail.read(path, on: host, limit: 10)
        XCTAssertEqual(host.reads, ["\(path) 89..<100"])
    }

    func testAMissingLogIsNil() throws {
        XCTAssertNil(try LogTail.read(path, on: host))
    }

    func testAnEmptyLogIsEmptyText() throws {
        host.put(path, modified: "2026-11-14 02:00")
        XCTAssertEqual(try LogTail.read(path, on: host), "")
    }

    func testBytesThatAreNotTextDoNotLoseTheRest() throws {
        host.put(path, modified: "2026-11-14 02:00", data: Data([0xFF]) + Data("päivä\n".utf8))
        XCTAssertEqual(try LogTail.read(path, on: host), "\u{FFFD}päivä\n")
    }

    func testAnUnreadableLogIsAnError() {
        host.makeUnreadable(path)
        XCTAssertThrowsError(try LogTail.read(path, on: host)) { error in
            XCTAssertEqual((error as? HostAccessError)?.message, "\(path) could not be read: permission denied")
        }
    }
}
