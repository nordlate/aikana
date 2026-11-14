@testable import AikanaCore
import XCTest

final class ConfigValuesTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(ConfigValues.duration("90s"), 90)
        XCTAssertEqual(ConfigValues.duration("30m"), 1800)
        XCTAssertEqual(ConfigValues.duration("26h"), 93600)
        XCTAssertEqual(ConfigValues.duration("2d"), 172_800)
        XCTAssertEqual(ConfigValues.duration("0m"), 0)
    }

    func testDurationRejectsAnythingElse() {
        for text in ["", "m", "30", "30 m", "1.5h", "-5m", "+5m", "5M", "1h30m", "1w", "1234567890s", "٣m"] {
            XCTAssertNil(ConfigValues.duration(text), text)
        }
    }

    func testByteCount() {
        XCTAssertEqual(ConfigValues.byteCount("512B"), 512)
        XCTAssertEqual(ConfigValues.byteCount("500KB"), 500_000)
        XCTAssertEqual(ConfigValues.byteCount("10MB"), 10_000_000)
        XCTAssertEqual(ConfigValues.byteCount("2GB"), 2_000_000_000)
        XCTAssertEqual(ConfigValues.byteCount("999999999GB"), 999_999_999_000_000_000)
    }

    func testByteCountRejectsAnythingElse() {
        for text in ["", "10", "MB", "10 MB", "10mb", "1.5GB", "-1MB", "10TB", "10MiB", "1234567890GB"] {
            XCTAssertNil(ConfigValues.byteCount(text), text)
        }
    }

    func testTimeOfDay() {
        XCTAssertEqual(ConfigValues.timeOfDay("00:00"), TimeOfDay(hour: 0, minute: 0))
        XCTAssertEqual(ConfigValues.timeOfDay("23:59"), TimeOfDay(hour: 23, minute: 59))
    }

    func testTimeOfDayRejectsAnythingElse() {
        for text in ["", "2:00", "02:0", "24:00", "02:60", "0200", "02:00:00", "02.00", " 02:00", "ab:cd"] {
            XCTAssertNil(ConfigValues.timeOfDay(text), text)
        }
    }
}

final class ConfigLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")

    func testDefaultIsUnderTheHomeDirectory() {
        XCTAssertEqual(resolve(explicit: nil, environment: [:]), "/Users/example/.config/aikana/config.json5")
    }

    func testEnvironmentVariableOverridesTheDefault() {
        XCTAssertEqual(resolve(explicit: nil, environment: ["AIKANA_CONFIG": "/etc/aikana.json5"]), "/etc/aikana.json5")
    }

    func testExplicitPathOverridesTheEnvironmentVariable() {
        XCTAssertEqual(resolve(explicit: "/tmp/mine.json5", environment: ["AIKANA_CONFIG": "/etc/aikana.json5"]), "/tmp/mine.json5")
    }

    func testEmptyValuesAreIgnored() {
        XCTAssertEqual(resolve(explicit: "", environment: ["AIKANA_CONFIG": ""]), "/Users/example/.config/aikana/config.json5")
    }

    func testTildeIsTheHomeDirectory() {
        XCTAssertEqual(resolve(explicit: "~/dotfiles/aikana.json5", environment: [:]), "/Users/example/dotfiles/aikana.json5")
    }

    private func resolve(explicit: String?, environment: [String: String]) -> String {
        ConfigLocation.resolve(explicitPath: explicit, environment: environment, homeDirectory: home).path
    }
}
