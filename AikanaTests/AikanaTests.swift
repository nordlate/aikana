@testable import Aikana
import AikanaCore
import XCTest

@MainActor
final class AikanaTests: XCTestCase {
    func testAppLinksTheEngine() {
        XCTAssertFalse(AikanaCore.version.isEmpty)
    }

    func testTheAppDoesNotWatchWhileItHostsTests() {
        XCTAssertTrue(WatchModel.isHostingTests)
    }
}
