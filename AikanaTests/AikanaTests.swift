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

    /// The `aikana` command line tool ships inside the app, at the same version.
    func testTheCommandLineToolShipsInsideTheApp() throws {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/aikana")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path), "no tool at \(tool.path)")

        let result = try ProcessCommandRunner().run(tool.path, arguments: ["--version"], timeout: 10)
        let appVersion = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "aikana \(appVersion)\n")
        XCTAssertEqual(appVersion, AikanaCore.version)
    }
}
