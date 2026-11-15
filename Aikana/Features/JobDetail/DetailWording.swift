import AikanaCore
import Foundation

/// The words of the job detail, kept apart from the views so they can be tested.
enum DetailWording {
    /// How many dots the run strip shows.
    static let runLimit = 14

    /// The verdict as a headline: "Failed today at 3:00", "Ran today at 4:05, on schedule".
    static func headline(of report: JobReport, now: Date = Date()) -> String {
        switch report.state {
        case .failed:
            if let run = report.runs.last, run.outcome == .failed {
                return "Failed \(Wording.dayAt(run.date, now: now))"
            }
            return "Failed"
        case .ok:
            guard let lastRun = report.lastRun else { return "OK" }
            let onSchedule = report.expectedRun != nil && report.runs.last?.outcome == .ok
            return "Ran \(Wording.dayAt(lastRun, now: now))" + (onSchedule ? ", on schedule" : "")
        case .missed:
            return report.expectedRun.map { "Missed the run due \(Wording.dayAt($0, now: now))" } ?? "Missed a run"
        case .waiting:
            return report.expectedRun.map { "Waiting for the run due \(Wording.dayAt($0, now: now))" } ?? "Waiting"
        case .running:
            return "Running now"
        case .stale:
            return "Not readable for long"
        case .unknown, .hostOffline:
            return report.state.title
        }
    }

    /// What explains the headline, when it needs explaining: "Exited with code 1 · 1 check failed".
    static func subline(of report: JobReport, now: Date = Date()) -> String? {
        switch report.state {
        case .ok:
            return nil
        case .missed:
            return report.lastRun.map { "Last ran \(Wording.recent($0, now: now))" } ?? "No run seen yet"
        case .failed:
            let failed = report.checks.count { if case .failed = $0.outcome.result { true } else { false } }
            let checks = failed == 0 ? nil : failed == 1 ? "1 check failed" : "\(failed) checks failed"
            return [Wording.sentence(Wording.shortReason(report.reason)), checks].compactMap { $0 }.joined(separator: " · ")
        case .running, .waiting, .stale, .unknown, .hostOffline:
            return report.reason.isEmpty ? nil : Wording.sentence(report.reason)
        }
    }

    /// The runs the strip shows, oldest first.
    static func shownRuns(of report: JobReport) -> [RunMark] {
        Array(report.runs.suffix(runLimit))
    }

    /// The words beside the strip: "Last 14 runs", "Last 5 runs on schedule".
    static func runsCaption(_ runs: [RunMark]) -> String {
        let all = runs.count == 1 ? "Last run" : "Last \(runs.count) runs"
        return runs.allSatisfy { $0.outcome == .ok } ? "\(all) on schedule" : all
    }

    /// "2 checks passed".
    static func passedCaption(count: Int) -> String {
        count == 1 ? "1 check passed" : "\(count) checks passed"
    }

    /// The scheduler and the job's name in it, from "launchd com.example.backup": ("launchd job", "com.example.backup").
    static func source(_ source: String) -> (name: String, value: String) {
        guard let space = source.firstIndex(of: " ") else { return ("Source", source) }
        return ("\(source[..<space]) job", String(source[source.index(after: space)...]))
    }

    /// The last two parts of a path, behind an ellipsis: "…/backups/latest.manifest". Shorter paths and words
    /// that are not paths are kept whole.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.contains("/"), parts.count > 3 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// What a check found, below its name. `nil` for one that passed.
    static func checkMessage(_ result: CheckOutcome.Result) -> String? {
        switch result {
        case .passed: nil
        case let .failed(message), let .couldNotRun(message): Wording.sentence(message)
        case let .skipped(message): "Not run yet: \(message)"
        }
    }

    /// One word or two for a check's result.
    static func checkResult(_ result: CheckOutcome.Result) -> String {
        switch result {
        case .passed: "Passed"
        case .failed: "Failed"
        case .couldNotRun: "Could not run"
        case .skipped: "Not run yet"
        }
    }

    /// "Latest 5 lines".
    static func linesCaption(count: Int) -> String {
        count == 1 ? "Latest line" : "Latest \(count) lines"
    }
}

extension Wording {
    /// A moment with "at": "today at 14:30", "Sat at 14:30", or the date too when it is further away.
    static func dayAt(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(time)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 7
        if abs(days) < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) at \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) at \(time)"
    }

    /// A reason without the words a short line does not need: "its last run exited with code 1" becomes
    /// "exited with code 1".
    static func shortReason(_ reason: String) -> String {
        let prefix = "its last run "
        return reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : reason
    }
}
