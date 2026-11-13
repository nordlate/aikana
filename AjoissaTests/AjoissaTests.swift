@testable import Ajoissa
import AjoissaCore
import XCTest

@MainActor
final class AjoissaTests: XCTestCase {
    func testAppLinksTheEngine() {
        XCTAssertFalse(AjoissaCore.version.isEmpty)
    }

    func testTheAppDoesNotWatchWhileItHostsTests() {
        XCTAssertTrue(WatchModel.isHostingTests)
    }
}
