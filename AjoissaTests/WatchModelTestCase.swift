@testable import Ajoissa
import AjoissaCore
import XCTest

/// Hands out the outcomes a test has lined up, one per round, and counts the rounds.
actor Rounds {
    private var outcomes: [WatchSession.Outcome]
    private(set) var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdsNext = false

    init(_ outcomes: [WatchSession.Outcome]) {
        self.outcomes = outcomes
    }

    /// Makes the next round wait until `release` is called.
    func holdNext() {
        holdsNext = true
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func next() async -> WatchSession.Outcome {
        count += 1
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { gate = $0 }
        }
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}

final class Fingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "1"

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The notifications a test's model sent.
actor Told {
    private(set) var announcements: [Announcement] = []

    func add(_ announcement: Announcement) {
        announcements.append(announcement)
    }
}

final class Switches: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Bool] = [:]

    var value: [String: Bool] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A model fed with lined-up rounds, with everything it reaches outside replaced.
@MainActor
class WatchModelTestCase: XCTestCase {
    let fingerprint = Fingerprint()
    let told = Told()
    let switches = Switches()

    func model(rounds: Rounds) -> WatchModel {
        let fingerprint = fingerprint
        let told = told
        let switches = switches
        return WatchModel(environment: WatchModel.Environment(
            configURL: URL(fileURLWithPath: "/tmp/example/config.json5"),
            historyURL: URL(fileURLWithPath: "/tmp/example/history.json"),
            round: { _ in await rounds.next() },
            configFingerprint: { fingerprint.value },
            readLog: { path, host in .text("\(host.id):\(path)") },
            deliver: { await told.add($0) },
            requestNotificationPermission: { true },
            readSwitch: { switches.value[$0] },
            writeSwitch: { name, value in switches.value[name] = value }
        ))
    }

    func looked(_ reports: JobReport...) -> WatchSession.Outcome {
        .looked(config: config(), reports: reports, alerts: [], saveProblem: nil)
    }

    func config() -> Config {
        // The jobs shown come from the reports; the config only says which machines there are.
        let text = "{ version: 1, jobs: [ { id: 'x', source: { launchd: 'com.example.x' } } ] }"
        // swiftlint:disable:next force_unwrapping
        return (try? ConfigLoader.load(Data(text.utf8)))!
    }

    func report(_ id: String, _ state: JobState) -> JobReport {
        let job = Job(id: id, name: id, hostID: "local", source: nil, schedule: nil, grace: Job.defaultGrace, notify: true, checks: [])
        return JobReport(job: job, state: state, reason: "")
    }
}
