import AikanaCore
import Foundation

enum ConfigFixture {
    static let exampleURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Examples/config.example.json5")

    static func load(_ text: String) throws(ConfigError) -> Config {
        try ConfigLoader.load(Data(text.utf8))
    }

    /// Every problem the loader reports for `text`, one line each. Empty when the config is valid.
    static func issues(_ text: String) -> [String] {
        do {
            _ = try load(text)
            return []
        } catch {
            return error.lines
        }
    }

    /// A config with one job. `job` is the inside of the job object, `hosts` the inside of the hosts list.
    static func config(job: String, hosts: String = "") -> String {
        "{ version: 1, hosts: [\(hosts)], jobs: [ { \(job) } ] }"
    }

    /// A config with one launchd job `a` that has one check. `check` is the inside of the check object.
    static func config(check: String) -> String {
        config(job: "id: 'a', source: { launchd: 'com.example.a' }, checks: [ { \(check) } ]")
    }

    /// The one job of a config built with `config(job:hosts:)`.
    static func job(_ job: String, hosts: String = "") throws -> Job {
        let config = try load(config(job: job, hosts: hosts))
        return try XCTUnwrapFirst(config.jobs)
    }

    /// The one check of a config built with `config(check:)`.
    static func check(_ check: String) throws -> Check {
        let config = try load(config(check: check))
        return try XCTUnwrapFirst(try XCTUnwrapFirst(config.jobs).checks)
    }

    private struct Empty: Error {}

    private static func XCTUnwrapFirst<Element>(_ list: [Element]) throws -> Element {
        guard let first = list.first else { throw Empty() }
        return first
    }
}
