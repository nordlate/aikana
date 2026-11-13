import AjoissaCore
import XCTest

/// What the log-pattern tests share: a host, the state one look leaves for the next, and two nights' runs.
class LogCheckTestCase: XCTestCase {
    var host: FakeHost!
    var state: CheckState?
    let log = "/var/log/job.log"
    let run1 = "2026-11-13 02:00"
    let run2 = "2026-11-14 02:00"

    override func setUp() {
        host = FakeHost()
        state = nil
    }

    // MARK: - Helpers

    @discardableResult
    func look(at moment: String, since: String?, _ check: Check, defaultLogPaths: [String] = []) -> CheckOutcome {
        let context = CheckContext(
            now: TestClock.date(moment),
            since: since.map { TestClock.date($0) },
            defaultLogPaths: defaultLogPaths,
            calendar: TestClock.utc
        )
        let result = CheckRunner.run([check], on: host, context: context, state: state)
        state = result.state
        return result.outcomes[0]
    }
}
