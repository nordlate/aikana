import Foundation

/// Decides whether a job is fine, from what is known about it now and what was remembered from before.
///
/// This is pure: it reads no clock and no files. The same inputs always give the same verdict.
///
/// For a job with calendar rules the question is: which scheduled time is the oldest one not yet accounted for?
/// A run seen at some moment accounts for every scheduled time up to that moment. If a scheduled time is still
/// open when its grace is over, the job is `missed`, and it stays `missed` until a run is seen. Asking about the
/// oldest open time, not the latest, is what keeps a stopped hourly job from looking fine again every hour.
///
/// For a job that repeats on an interval there are no scheduled times. The question is whether too long has
/// passed since the last run that was seen.
public enum JobEvaluator {
    /// How much earlier than its scheduled time a run may appear to have happened and still count for it.
    /// Evidence is timestamped by whoever saw it, and clocks and file systems do not agree to the second.
    public static let tolerance: TimeInterval = 60
    /// How long a job's state may stay unreadable before that itself is reported as a problem.
    public static let staleAfter: TimeInterval = 24 * 60 * 60
    /// How many verdicts a record keeps.
    public static let transitionLimit = 50

    /// - Parameters:
    ///   - job: The job as configured.
    ///   - evidence: What is known about it at `now`.
    ///   - previous: The record from the last evaluation, or `nil` for a job seen for the first time.
    ///   - now: The moment of evaluation.
    ///   - calendar: The calendar and time zone the job's timetable is read in.
    public static func evaluate(job: Job, evidence: Evidence, previous: JobRecord?, now: Date, calendar: Calendar) -> JobEvaluation {
        var pass = EvaluationPass(job: job, evidence: evidence, previous: previous, now: now, calendar: calendar)
        return pass.run()
    }
}

/// One evaluation of one job. Its parts are spread over a few files; all of them are internal to the engine.
struct EvaluationPass {
    let job: Job
    let evidence: Evidence
    let previous: JobRecord?
    let now: Date
    let calendar: Calendar
    var record: JobRecord
    /// The scheduled time the verdict is about, and the one after now. Set once they are known.
    var expectedRun: Date?
    var nextRun: Date?

    init(job: Job, evidence: Evidence, previous: JobRecord?, now: Date, calendar: Calendar) {
        self.job = job
        self.evidence = evidence
        self.previous = previous
        self.now = now
        self.calendar = calendar
        record = previous ?? JobRecord(watchingSince: now)
    }

    mutating func run() -> JobEvaluation {
        guard evidence.hostReachable else {
            return finish(.hostOffline, "its host cannot be reached")
        }
        switch evidence.source?.availability {
        case let .unknown(reason):
            return finishUnreadable(reason)
        case .missing:
            record.unavailableSince = record.unavailableSince ?? now
            return finish(.failed, "the scheduler does not know this job and it has no definition, so it will not run")
        case .notLoaded:
            record.unavailableSince = record.unavailableSince ?? now
            return finish(.failed, "the scheduler has not loaded this job, so it will not run")
        case .available, nil:
            break
        }
        if record.unavailableSince != nil {
            // The job could not run while it was not loaded, so nothing from that time can have been missed.
            record.unavailableSince = nil
            startWatchOver()
        }
        guard let timetable = currentTimetable() else {
            return finishUnreadable("its timetable could not be read")
        }
        noteRuns(timetable)
        if evidence.source == nil {
            return decideFromChecksAlone(timetable)
        }
        if !timetable.calendarRules.isEmpty {
            return decideByCalendar(timetable)
        }
        if let interval = timetable.interval {
            return decideByInterval(interval)
        }
        return decideWithoutTimetable()
    }

    // MARK: - The timetable

    /// The timetable to judge by, or `nil` when there should be one and it is not known.
    mutating func currentTimetable() -> Timetable? {
        // A schedule stated in the config wins over the one read from the scheduler. When the scheduler's could
        // not be read this time, the one it had last time is the best there is: assuming "no timetable" would
        // call a job fine that may be overdue.
        guard let timetable = job.schedule.map(Timetable.init(schedule:)) ?? evidence.source?.timetable ?? record.timetable else {
            return nil
        }
        if let known = record.timetable, known != timetable {
            // A run that was due under the new timetable before it existed cannot have been missed.
            startWatchOver()
        }
        record.timetable = timetable
        return timetable
    }

    /// From now on is all that is judged: what was open or counted before no longer applies.
    mutating func startWatchOver() {
        record.watchingSince = now
        record.openRun = nil
        record.openRunGraceFrom = nil
        record.intervalFrom = nil
    }

    // MARK: - No scheduler, or no timetable

    /// A job with no scheduler to ask is judged by its checks alone, once its latest run has had its time.
    mutating func decideFromChecksAlone(_ timetable: Timetable) -> JobEvaluation {
        let awakeSince = evidence.awakeSince ?? .distantPast
        let deadline: Date
        if let due = timetable.lastCalendarOccurrence(onOrBefore: now, calendar: calendar) {
            expectedRun = due
            nextRun = timetable.nextCalendarOccurrence(after: now, calendar: calendar)
            deadline = max(due, awakeSince).addingTimeInterval(job.grace)
        } else {
            deadline = max(record.watchingSince, awakeSince).addingTimeInterval((timetable.interval ?? 0) + job.grace)
        }
        if now <= deadline, !evidence.checks.allSatisfy({ $0.result == .passed }) {
            let run = expectedRun.map { "the run due at \(stamp($0))" } ?? "the next run"
            return finish(.waiting, "its checks do not pass yet; \(run) has until \(stamp(deadline))")
        }
        return verdictOnChecks() ?? finish(.ok, "its checks pass")
    }

    /// A job that runs on demand or on some event has no run to wait for. Only its last result can be judged.
    mutating func decideWithoutTimetable() -> JobEvaluation {
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        return verdictOnLastExit() ?? verdictOnChecks() ?? finish(.ok, "it has no timetable, and nothing is known to be wrong")
    }

    // MARK: - Parts of a verdict

    mutating func verdictOnLastExit() -> JobEvaluation? {
        evidence.source?.lastExit?.problem.map { finish(.failed, "its last run \($0)") }
    }

    /// The verdict the checks force, if any: a failed check, or one that could not be carried out.
    mutating func verdictOnChecks() -> JobEvaluation? {
        for check in evidence.checks {
            if case let .failed(message) = check.result {
                return finish(.failed, message)
            }
        }
        for check in evidence.checks {
            if case let .couldNotRun(message) = check.result {
                return finish(.unknown, message)
            }
        }
        return nil
    }

    func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    // MARK: - Finishing

    /// The state could not be read. That is its own state, and after long enough a problem of its own.
    mutating func finishUnreadable(_ reason: String) -> JobEvaluation {
        let since = record.unreadableSince ?? now
        record.unreadableSince = since
        if now.timeIntervalSince(since) >= JobEvaluator.staleAfter {
            return finish(.stale, "its state has not been readable since \(stamp(since)): \(reason)")
        }
        return finish(.unknown, reason)
    }

    mutating func finish(_ state: JobState, _ reason: String) -> JobEvaluation {
        let differs = previous?.state != state
        if differs {
            record.stateSince = now
        }
        var changed = differs
        if let before = previous?.state {
            if before.isUnreadable, !state.isUnreadable {
                // Back from not being able to look. Finding the job as it was left is not news.
                changed = state != record.stateBeforeUnreadable
            } else if !before.isUnreadable, state.isUnreadable {
                record.stateBeforeUnreadable = before
            }
        }
        if !state.isUnreadable {
            record.stateBeforeUnreadable = nil
        }
        // `waiting`, `running` and `unknown` come and go. Listing them would push the verdicts that matter out
        // of the record within days.
        if ![.waiting, .running, .unknown].contains(state), record.transitions.last?.state != state {
            record.transitions.append(JobRecord.Transition(date: now, state: state, reason: reason))
            record.transitions.removeFirst(max(0, record.transitions.count - JobEvaluator.transitionLimit))
        }
        if state != .unknown, state != .stale {
            record.unreadableSince = nil
        }
        record.state = state
        record.reason = reason
        record.lastEvaluatedAt = now
        return JobEvaluation(state: state, reason: reason, expectedRun: expectedRun, nextRun: nextRun, changed: changed, record: record)
    }
}
