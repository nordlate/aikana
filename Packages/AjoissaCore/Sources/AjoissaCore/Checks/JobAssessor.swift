import Foundation

/// Looks at one job from start to finish: what its scheduler says, what its checks find, and the verdict.
///
/// The checks ask "since the last expected run", and which run that is depends on the evaluation. So the job is
/// evaluated once without its checks to learn that, the checks are run, and it is evaluated again with what
/// they found. Both evaluations start from the same record; only the second is kept.
public enum JobAssessor {
    public struct Assessment: Sendable, Equatable {
        public var evaluation: JobEvaluation
        /// One outcome per check of the job, in order. Empty when the checks were not run.
        public var outcomes: [CheckOutcome]
    }

    // Each parameter is a separate thing the caller has in hand; bundling them would only add a type to unpack.
    // swiftlint:disable function_parameter_count

    /// - Parameters:
    ///   - evidence: What is known about the job, without check outcomes; those are produced here.
    ///   - host: The machine the job runs on.
    ///   - defaultLogPaths: The job's own log files, for a `log-pattern` check that names none.
    public static func assess(
        job: Job,
        evidence: Evidence,
        host: any HostAccess,
        defaultLogPaths: [String] = [],
        previous: JobRecord?,
        now: Date,
        calendar: Calendar
    ) -> Assessment {
        var evidence = evidence
        evidence.checks = []
        let first = JobEvaluator.evaluate(job: job, evidence: evidence, previous: previous, now: now, calendar: calendar)
        guard !job.checks.isEmpty, checksApply(first, evidence) else {
            return Assessment(evaluation: first, outcomes: [])
        }
        let context = CheckContext(
            now: now,
            since: first.checksSince,
            outputSince: first.outputSince,
            // A job on an interval has no scheduled time for a log line to be newer than.
            logProvesRun: first.expectedRun != nil,
            // For a job with a scheduler, a run that has not been seen yet is waited for or missed.
            runIsOpen: evidence.source != nil && [.waiting, .missed].contains(first.state),
            defaultLogPaths: defaultLogPaths,
            calendar: calendar
        )
        let (outcomes, state) = CheckRunner.run(job.checks, on: host, context: context, state: previous?.checkState)
        evidence.checks = outcomes
        var evaluation = JobEvaluator.evaluate(job: job, evidence: evidence, previous: previous, now: now, calendar: calendar)
        evaluation.record.checkState = state
        return Assessment(evaluation: evaluation, outcomes: outcomes)
    }

    // swiftlint:enable function_parameter_count

    /// Whether there is any point in running the checks now.
    private static func checksApply(_ evaluation: JobEvaluation, _ evidence: Evidence) -> Bool {
        // A job that is running has not produced its result yet, and one that cannot be looked at or cannot
        // run has no result to check.
        if evaluation.state == .running || evaluation.state.isUnreadable {
            return false
        }
        switch evidence.source?.availability {
        case .available, nil: return true
        case .notLoaded, .missing, .unknown: return false
        }
    }
}

extension Check {
    /// The check in a few words, as it is written in the config: "file-age ~/Reports/*.md".
    public var label: String {
        switch self {
        case let .fileAge(path, _): "file-age \(path)"
        case let .fileSize(path, _): "file-size \(path)"
        case let .command(arguments, _): "command \(arguments.first ?? "")"
        case let .logPattern(path, _, _): "log-pattern \(path ?? "(the job's log)")"
        }
    }
}

extension CheckOutcome {
    /// The result in one line: "passed", "failed: …" or "could not be carried out: …".
    public var summary: String {
        switch result {
        case .passed: "passed"
        case let .failed(message): "failed: \(message)"
        case let .couldNotRun(message): "could not be carried out: \(message)"
        case let .skipped(message): "not run yet: \(message)"
        }
    }
}
