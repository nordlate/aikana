import Foundation

extension EvaluationPass {
    // MARK: - What is known about runs

    /// Updates the record with what the evidence says about when the job last ran.
    mutating func noteRuns(_ timetable: Timetable) {
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
        if source.isRunning == true {
            // A run in progress is a run. The scheduler does not start another while it lasts, so it accounts
            // for a scheduled time that passes meanwhile.
            latest = now
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
    func creditedRun(started: Int, since: Date, timetable: Timetable) -> Date {
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

    static func later(_ first: Date?, _ second: Date?) -> Date? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }
}
