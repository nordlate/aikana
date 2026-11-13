import AjoissaCore
import XCTest

final class AjoissaCoreTests: XCTestCase {
    func testVersionIsThreePartSemver() {
        let parts = AjoissaCore.version.split(separator: ".", omittingEmptySubsequences: false)

        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
