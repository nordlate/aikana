import Foundation

/// Decides whether a job is fine, from what is known about it now and what was remembered from before.
///
/// This is pure: it reads no clock and no files. The same inputs always give the same verdict.
public enum JobEvaluator {
    /// How much earlier than its scheduled time a run may appear to have happened and still count for it.
    /// Evidence is timestamped by whoever saw it, and clocks and file systems do not agree to the second.
    public static let tolerance: TimeInterval = 60
    /// How long a job's state may stay unreadable before that itself is reported as a problem.
    public static let staleAfter: TimeInterval = 24 * 60 * 60
    /// How many changes of state a record keeps.
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

/// What a job has to have done by now.
private struct Requirement {
    /// The scheduled time in question, for calendar rules.
    var due: Date?
    var next: Date?
    /// A run counts if it happened no earlier than this.
    var since: Date
    /// Until this moment a missing run is not yet a missed run.
    var deadline: Date
    /// False when the run was due before anyone was watching, so its absence proves nothing.
    var judgeable: Bool
}

private struct Pass {
    let job: Job
    let evidence: Evidence
    let previous: JobRecord?
    let now: Date
    let calendar: Calendar
    let timetable: Timetable?
    var record: JobRecord
    var requirement: Requirement?

    init(job: Job, evidence: Evidence, previous: JobRecord?, now: Date, calendar: Calendar) {
        self.job = job
        self.evidence = evidence
        self.previous = previous
        self.now = now
        self.calendar = calendar
        // A schedule stated in the config wins over the one read from the scheduler.
        timetable = job.schedule.map(Timetable.init(schedule:)) ?? evidence.source?.timetable
        var record = previous ?? JobRecord(watchingSince: now)
        if let timetable {
            // A run that was due under the new timetable before it existed cannot have been missed.
            if previous != nil, record.timetable != nil, record.timetable != timetable {
                record.watchingSince = now
            }
            record.timetable = timetable
        }
        self.record = record
    }

    mutating func run() -> JobEvaluation {
        guard evidence.hostReachable else {
            return finish(.hostOffline, "its host cannot be reached")
        }
        switch evidence.source?.availability {
        case let .unknown(reason):
            return finishUnreadable(reason)
        case .missing:
            return finish(.failed, "the scheduler does not know this job and it has no definition, so it will not run")
        case .notLoaded:
            return finish(.failed, "the scheduler has not loaded this job, so it will not run")
        case .available, nil:
            break
        }
        guard let timetable, !timetable.isEmpty, let requirement = requirement(for: timetable) else {
            return decideWithoutTimetable()
        }
        self.requirement = requirement
        noteRuns(requirement: requirement, timetable: timetable)
        return decide(requirement)
    }

    // MARK: - What is required

    private func requirement(for timetable: Timetable) -> Requirement? {
        let awakeSince = evidence.awakeSince ?? .distantPast
        if !timetable.calendarRules.isEmpty {
            // With calendar rules the question is about one scheduled time: the latest that has passed.
            guard let due = timetable.lastCalendarOccurrence(onOrBefore: now, calendar: calendar) else { return nil }
            return Requirement(
                due: due,
                next: timetable.nextCalendarOccurrence(after: now, calendar: calendar),
                since: due.addingTimeInterval(-JobEvaluator.tolerance),
                // A time that passed while the machine slept is made up for on wake, so the grace starts there.
                deadline: max(due, awakeSince).addingTimeInterval(job.grace),
                judgeable: due >= record.watchingSince.addingTimeInterval(-JobEvaluator.tolerance)
            )
        }
        guard let interval = timetable.interval else { return nil }
        // An interval has no fixed times. The question is whether a run happened recently enough. Time asleep
        // does not count towards the interval, and neither does time before anyone was watching.
        return Requirement(
            due: nil,
            next: nil,
            since: now.addingTimeInterval(-interval - job.grace),
            deadline: max(record.watchingSince, awakeSince).addingTimeInterval(interval + job.grace),
            judgeable: true
        )
    }

    // MARK: - What is known about runs

    /// Updates the record with what the evidence says about when the job last ran.
    private mutating func noteRuns(requirement: Requirement, timetable: Timetable) {
        guard let source = evidence.source else { return }
        var latest = record.lastRun
        if let count = source.runCount {
            if let earlier = record.lastRunCount, let earlierDate = record.lastObservedAt, count != earlier {
                // A higher count means that many runs started since it was last read. A lower one means the job
                // was reloaded in between, and every run it now counts started after that.
                let started = count > earlier ? count - earlier : count
                if started > 0 {
                    latest = Self.later(latest, creditedRun(started: started, since: earlierDate, requirement: requirement, timetable: timetable))
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

    /// When the count shows runs started after `since`, the latest of them is known to be no earlier than `since`.
    /// If `since` is before the required time, that alone does not show the required run happened. It does when
    /// as many runs started as were scheduled in between: then none of the scheduled ones is missing.
    private func creditedRun(started: Int, since: Date, requirement: Requirement, timetable: Timetable) -> Date {
        guard since < requirement.since else { return since }
        let scheduled: Int
        if timetable.calendarRules.isEmpty, let interval = timetable.interval {
            scheduled = max(1, Int(now.timeIntervalSince(since) / interval))
        } else {
            scheduled = max(1, timetable.calendarOccurrenceCount(after: since, through: now, calendar: calendar))
        }
        return started >= scheduled ? requirement.since : since
    }

    private static func later(_ first: Date?, _ second: Date?) -> Date? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }

    // MARK: - The verdict

    private mutating func decide(_ requirement: Requirement) -> JobEvaluation {
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        let provedByCheck = evidence.checks.contains { $0.provesRun && $0.result == .passed }
        let ran = provedByCheck || (record.lastRun ?? .distantPast) >= requirement.since
        if ran {
            return verdictOnCompletedRun() ?? finish(.ok, ranReason(requirement))
        }
        guard evidence.source != nil else {
            return decideFromChecksAlone(requirement)
        }
        if requirement.judgeable, now > requirement.deadline {
            return finish(.missed, missedReason(requirement))
        }
        // No run yet, and none can be demanded yet. An earlier run that went wrong is still the latest news.
        if let problem = evidence.source?.lastExit?.problem {
            return finish(.failed, "its last run \(problem)")
        }
        return finish(.waiting, waitingReason(requirement))
    }

    /// The verdict for a job whose required run happened, if anything about it is wrong.
    private mutating func verdictOnCompletedRun() -> JobEvaluation? {
        if let problem = evidence.source?.lastExit?.problem {
            return finish(.failed, "its last run \(problem)")
        }
        return verdictOnChecks()
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

    /// A job with no scheduler to ask is judged by its checks, once its run has had its time.
    private mutating func decideFromChecksAlone(_ requirement: Requirement) -> JobEvaluation {
        let allPassed = evidence.checks.allSatisfy { $0.result == .passed }
        if now <= requirement.deadline {
            return allPassed ? finish(.ok, "its checks pass") : finish(.waiting, waitingReason(requirement))
        }
        return verdictOnChecks() ?? finish(.ok, "its checks pass")
    }

    /// A job that runs on demand or on some event has no run to wait for. Only its last result can be judged.
    private mutating func decideWithoutTimetable() -> JobEvaluation {
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        return verdictOnCompletedRun() ?? finish(.ok, "it has no timetable, and nothing is known to be wrong")
    }

    // MARK: - Reasons

    private func ranReason(_ requirement: Requirement) -> String {
        if let due = requirement.due {
            return "the run due at \(stamp(due)) happened"
        }
        return "it has run since \(stamp(requirement.since))"
    }

    private func missedReason(_ requirement: Requirement) -> String {
        if let due = requirement.due {
            return "there is no sign of the run that was due at \(stamp(due))"
        }
        return "there is no sign of a run since \(stamp(requirement.since))"
    }

    private func waitingReason(_ requirement: Requirement) -> String {
        guard let due = requirement.due else {
            return "no run has been seen yet; one is expected by \(stamp(requirement.deadline))"
        }
        guard requirement.judgeable else {
            let next = requirement.next.map { "; the next run is due at \(stamp($0))" } ?? ""
            return "the run due at \(stamp(due)) was before Ajoissa started watching\(next)"
        }
        return "the run due at \(stamp(due)) has not been seen yet; it has until \(stamp(requirement.deadline))"
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
            record.transitions.append(JobRecord.Transition(date: now, state: state, reason: reason))
            record.transitions.removeFirst(max(0, record.transitions.count - JobEvaluator.transitionLimit))
        }
        if state != .unknown, state != .stale {
            record.unreadableSince = nil
        }
        record.state = state
        record.reason = reason
        record.lastEvaluatedAt = now
        return JobEvaluation(
            state: state,
            reason: reason,
            expectedRun: requirement?.due,
            nextRun: requirement?.next,
            changed: changed,
            record: record
        )
    }
}
