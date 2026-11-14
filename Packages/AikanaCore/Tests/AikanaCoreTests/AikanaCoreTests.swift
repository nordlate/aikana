import AikanaCore
import XCTest

final class AikanaCoreTests: XCTestCase {
    func testVersionIsThreePartSemver() {
        let parts = AikanaCore.version.split(separator: ".", omittingEmptySubsequences: false)

        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
