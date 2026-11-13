import Foundation

extension EvaluationPass {
    // MARK: - Calendar rules

    mutating func decideByCalendar(_ timetable: Timetable) -> JobEvaluation {
        let latestDue = timetable.lastCalendarOccurrence(onOrBefore: now, calendar: calendar)
        nextRun = timetable.nextCalendarOccurrence(after: now, calendar: calendar)
        guard latestDue != nil || nextRun != nil else {
            // Rules that never match, such as 30 February.
            return decideWithoutTimetable()
        }
        var open = openRun(timetable)
        if let due = open, let proof = proofOfRun(noEarlierThan: due.addingTimeInterval(-JobEvaluator.tolerance)) {
            // A check shows the job has run since that scheduled time, whether or not the run itself was seen.
            // The run is credited at the moment the proof is from, so it accounts for every scheduled time up
            // to then and for none after.
            record.lastRun = Self.later(record.lastRun, proof)
            open = openRun(timetable)
        }
        expectedRun = open ?? latestDue
        runBeforeExpected = expectedRun.flatMap {
            timetable.lastCalendarOccurrence(onOrBefore: $0.addingTimeInterval(-1), calendar: calendar)
        }
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
        guard let due = open else {
            record.openRun = nil
            record.openRunGraceFrom = nil
            return decideWithNothingOpen(latestDue: latestDue)
        }
        let deadline = graceStart(for: due).addingTimeInterval(job.grace)
        if now > deadline {
            return finish(.missed, "there is no sign of the run that was due at \(stamp(due))")
        }
        // The run still has time. An earlier run that went wrong is the latest news until it shows up.
        return verdictOnLastExit()
            ?? finish(.waiting, "the run due at \(stamp(due)) has not been seen yet; it has until \(stamp(deadline))")
    }

    /// The moment the grace for an open scheduled time counts from. Normally that is the scheduled time. If
    /// the machine was asleep or off then, the scheduler makes up for it on wake, so the grace counts from the
    /// wake. This is settled once, when the scheduled time is first found open: a wake long after a run was
    /// already missed must not give it more time.
    mutating func graceStart(for due: Date) -> Date {
        if record.openRun == due, let settled = record.openRunGraceFrom {
            return settled
        }
        var from = due
        let lookedSinceDue = previous.map { $0.lastEvaluatedAt >= due } ?? false
        if !lookedSinceDue, let woke = evidence.awakeSince, woke > due, woke <= now {
            from = woke
        }
        record.openRun = due
        record.openRunGraceFrom = from
        return from
    }

    mutating func decideWithNothingOpen(latestDue: Date?) -> JobEvaluation {
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
    func openRun(_ timetable: Timetable) -> Date? {
        // A run accounts for every scheduled time up to the moment it was seen, give or take the tolerance.
        let accountedFor = (record.lastRun ?? .distantPast).addingTimeInterval(JobEvaluator.tolerance)
        // Only times after the watch began are judged. One that had just passed may already have been run, and
        // that run is in the count the watch started from.
        guard let due = timetable.nextCalendarOccurrence(after: max(accountedFor, record.watchingSince), calendar: calendar), due <= now else {
            return nil
        }
        return due
    }

    // MARK: - Interval

    mutating func decideByInterval(_ interval: TimeInterval) -> JobEvaluation {
        // A file or log line newer than this shows a run within the stretch that must have had one.
        intervalWindowStart = now.addingTimeInterval(-interval - job.grace)
        hasNoScheduledTimes = true
        if let proof = proofOfRun(noEarlierThan: .distantPast) {
            // Credited when the proof is from, not now: a file from the last run must not keep a job that has
            // since stopped looking alive.
            record.lastRun = Self.later(record.lastRun, proof)
        }
        let from = intervalStart()
        let deadline = from.addingTimeInterval(interval + job.grace)
        if evidence.source?.isRunning == true {
            return finish(.running, "it is running now")
        }
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

    /// The moment the interval is counted from: the last run that was seen, or else the start of the watch.
    /// Time asleep does not count towards the interval, so the moment moves on by the length of each sleep.
    /// It never moves for any other reason, so a job that is overdue stays overdue through a wake.
    mutating func intervalStart() -> Date {
        var from = record.intervalFrom ?? record.watchingSince
        if let woke = evidence.awakeSince, let lastLook = previous?.lastEvaluatedAt, woke > lastLook, woke <= now {
            // Nobody looked between the last evaluation and the wake: that stretch is the sleep.
            from = from.addingTimeInterval(woke.timeIntervalSince(lastLook))
        }
        if let lastRun = record.lastRun, lastRun > from {
            from = lastRun
        }
        from = min(from, now)
        record.intervalFrom = from
        return from
    }
}
