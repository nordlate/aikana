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
        var pass = Pass(job: job, evidence: evidence, previous: previous, now: now, calendar: calendar)
        return pass.run()
    }
}

private struct Pass {
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
            record.watchingSince = now
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
    private mutating func currentTimetable() -> Timetable? {
        // A schedule stated in the config wins over the one read from the scheduler. When the scheduler's could
        // not be read this time, the one it had last time is the best there is: assuming "no timetable" would
        // call a job fine that may be overdue.
        guard let timetable = job.schedule.map(Timetable.init(schedule:)) ?? evidence.source?.timetable ?? record.timetable else {
            return nil
        }
        if let known = record.timetable, known != timetable {
            // A run that was due under the new timetable before it existed cannot have been missed.
            record.watchingSince = now
        }
        record.timetable = timetable
        return timetable
    }

    // MARK: - What is known about runs

    /// Updates the record with what the evidence says about when the job last ran.
    private mutating func noteRuns(_ timetable: Timetable) {
        guard let source = evidence.source else { return }
        var latest = record.lastRun
        if let count = source.runCount {
            if let earlierCount = record.lastRunCount, let earlierDate = record.lastObservedAt {
                // The count starts over when the machine restarts or the job is reloaded. After a restart every
                // run it counts is new, even if the number happens to be what it was. Without one, a lower
                // number means a reload, and again every run it counts is new.
                let restarted = evidence.bootedAt.map { $0 > earlierDate } ?? false
                let started = restarted || count < earlierCount ? count : count - earlierCount
                if started > 0 {
                    latest = Self.later(latest, creditedRun(started: started, since: earlierDate, timetable: timetable))
                }
            }
            record.lastRunCount = count
            record.lastObservedAt = now
        }
        // A timestamp from the future is a clock problem and proves nothing. Treating it as "now" would make it
        // count as a fresh run at every evaluation, so it is left out.
        let latestBelievable = now.addingTimeInterval(JobEvaluator.tolerance)
        for case let moment? in [source.lastRunStarted, source.logModified] where moment <= latestBelievable {
            latest = Self.later(latest, min(moment, now))
        }
        record.lastRun = latest
    }

    /// The moment to credit for runs that started some time after `since`, when the count was last read.
    ///
    /// All that is certain is that they started after `since`. Two things narrow it down. Nothing runs while the
    /// machine is asleep or off, so if it woke in between, they started after the wake. And if as many runs
    /// started as were scheduled in that time, none of the scheduled ones is missing, and the latest scheduled
    /// time can be credited. Scheduled times that passed during sleep are made up for by one run on wake, so
    /// together they count as one.
    private func creditedRun(started: Int, since: Date, timetable: Timetable) -> Date {
        if timetable.calendarRules.isEmpty {
            // An interval has no scheduled times to tell apart. Crediting the moment the run was noticed can be
            // late by the time between two looks, which only delays a verdict; crediting `since` could be early
            // by as much, which would raise a false alarm.
            return now
        }
        let woke = evidence.awakeSince.flatMap { $0 > since && $0 <= now ? $0 : nil }
        let earliest = woke ?? since
        let sleptThroughOne = woke != nil
            && (timetable.nextCalendarOccurrence(after: since, calendar: calendar).map { $0 <= earliest } ?? false)
        // Counting stops as soon as it is clear that more were scheduled than started.
        let scheduledAwake = timetable.calendarOccurrenceCount(after: earliest, through: now, calendar: calendar, limit: started + 1)
        let scheduled = scheduledAwake + (sleptThroughOne ? 1 : 0)
        guard scheduled > 0, started >= scheduled,
              let latestDue = timetable.lastCalendarOccurrence(onOrBefore: now, calendar: calendar) else {
            return earliest
        }
        return max(earliest, latestDue)
    }

    private static func later(_ first: Date?, _ second: Date?) -> Date? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }

    // MARK: - Calendar rules

    private mutating func decideByCalendar(_ timetable: Timetable) -> JobEvaluation {
        let latestDue = timetable.lastCalendarOccurrence(onOrBefore: now, calendar: calendar)
        nextRun = timetable.nextCalendarOccurrence(after: now, calendar: calendar)
        guard latestDue != nil || nextRun != nil else {
            // Rules that never match, such as 30 February.
            return decideWithoutTimetable()
        }
        var open = openRun(timetable)
        if let due = open, evidence.checks.contains(where: { $0.provesRun && $0.result == .passed }) {
            // A check shows the job has run since that scheduled time, whether or not the run itself was seen.
            record.lastRun = Self.later(record.lastRun, due)
            open = openRun(timetable)
        }
        expectedRun = open ?? latestDue
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        if let due = open {
            // A time that passed while the machine slept is made up for on wake, so the grace starts there.
            let deadline = max(due, evidence.awakeSince ?? due).addingTimeInterval(job.grace)
            if now > deadline {
                return finish(.missed, "there is no sign of the run that was due at \(stamp(due))")
            }
            // The run still has time. An earlier run that went wrong is the latest news until it shows up.
            return verdictOnLastExit()
                ?? finish(.waiting, "the run due at \(stamp(due)) has not been seen yet; it has until \(stamp(deadline))")
        }
        if let problem = verdictOnLastExit() ?? verdictOnChecks() {
            return problem
        }
        guard let latestDue, let lastRun = record.lastRun, lastRun >= latestDue.addingTimeInterval(-JobEvaluator.tolerance) else {
            // Nothing is open, yet no run is known for the latest scheduled time: it was before the watch began.
            let due = latestDue.map { "the run due at \(stamp($0)) was before Ajoissa started watching" } ?? "no run has been due yet"
            let next = nextRun.map { "; the next run is due at \(stamp($0))" } ?? ""
            return finish(.waiting, due + next)
        }
        return finish(.ok, "the run due at \(stamp(latestDue)) happened")
    }

    /// The oldest scheduled time that has passed, was due while the job was being watched, and has no run to
    /// account for it.
    private func openRun(_ timetable: Timetable) -> Date? {
        // A run accounts for every scheduled time up to the moment it was seen, give or take the tolerance.
        let accountedFor = (record.lastRun ?? .distantPast).addingTimeInterval(JobEvaluator.tolerance)
        // The occurrence search is strict, so step just before the first moment that is judged.
        let watched = record.watchingSince.addingTimeInterval(-JobEvaluator.tolerance - 1)
        guard let due = timetable.nextCalendarOccurrence(after: max(accountedFor, watched), calendar: calendar), due <= now else {
            return nil
        }
        return due
    }

    // MARK: - Interval

    private mutating func decideByInterval(_ interval: TimeInterval) -> JobEvaluation {
        if evidence.checks.contains(where: { $0.provesRun && $0.result == .passed }) {
            record.lastRun = now
        }
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        // The interval is counted from the last run that was seen. Time asleep does not count towards it, and
        // neither does time before anyone was watching.
        let from = [record.lastRun, record.watchingSince, evidence.awakeSince].compactMap { $0 }.max() ?? now
        let deadline = from.addingTimeInterval(interval + job.grace)
        if now > deadline {
            return finish(.missed, "there is no sign of a run since \(stamp(from))")
        }
        if let problem = verdictOnLastExit() {
            return problem
        }
        // A run from long before the watch began says nothing about whether the job still runs.
        let earliestRelevant = record.watchingSince.addingTimeInterval(-interval - job.grace)
        guard let lastRun = record.lastRun, lastRun >= earliestRelevant else {
            return finish(.waiting, "no run has been seen yet; one is expected by \(stamp(deadline))")
        }
        return verdictOnChecks() ?? finish(.ok, "it last ran around \(stamp(lastRun)); the next run is expected by \(stamp(deadline))")
    }

    // MARK: - No scheduler, or no timetable

    /// A job with no scheduler to ask is judged by its checks alone, once its latest run has had its time.
    private mutating func decideFromChecksAlone(_ timetable: Timetable) -> JobEvaluation {
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
    private mutating func decideWithoutTimetable() -> JobEvaluation {
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        return verdictOnLastExit() ?? verdictOnChecks() ?? finish(.ok, "it has no timetable, and nothing is known to be wrong")
    }

    // MARK: - Parts of a verdict

    private mutating func verdictOnLastExit() -> JobEvaluation? {
        evidence.source?.lastExit?.problem.map { finish(.failed, "its last run \($0)") }
    }

    /// The verdict the checks force, if any: a failed check, or one that could not be carried out.
    private mutating func verdictOnChecks() -> JobEvaluation? {
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

    private func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    // MARK: - Finishing

    /// The state could not be read. That is its own state, and after long enough a problem of its own.
    private mutating func finishUnreadable(_ reason: String) -> JobEvaluation {
        let since = record.unreadableSince ?? now
        record.unreadableSince = since
        if now.timeIntervalSince(since) >= JobEvaluator.staleAfter {
            return finish(.stale, "its state has not been readable since \(stamp(since)): \(reason)")
        }
        return finish(.unknown, reason)
    }

    private mutating func finish(_ state: JobState, _ reason: String) -> JobEvaluation {
        let changed = previous?.state != state
        if changed {
            record.stateSince = now
        }
        // `waiting` and `running` come and go around every run. Listing them would push the verdicts that
        // matter out of the record within days.
        if state != .waiting, state != .running, record.transitions.last?.state != state {
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
