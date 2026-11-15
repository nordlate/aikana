import Foundation

/// One run of a job as it is remembered for showing: when, and how it went.
public struct RunMark: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        case ok
        case failed
        case missed
    }

    /// The scheduled time the run was for, or for a job without scheduled times the moment it was seen to run.
    /// For a missed run on an interval, the moment it was found missing.
    public var date: Date
    public var outcome: Outcome

    public init(date: Date, outcome: Outcome) {
        self.date = date
        self.outcome = outcome
    }
}

/// Keeps the recent runs of a job for showing. It reads only what an evaluation decided and never feeds back
/// into a verdict.
///
/// A run's outcome is the verdict the job settled on while that run was the one in question, so a run that is
/// found late, or whose checks fail after it has been seen, ends up with its final verdict. `waiting`,
/// `running` and the states that say nothing about the job leave the runs as they are.
public enum RunLog {
    /// How many runs are kept.
    public static let limit = 30

    /// `runs` with what the evaluation says about the run in question.
    public static func note(_ evaluation: JobEvaluation, in runs: [RunMark]) -> [RunMark] {
        let record = evaluation.record
        let mark: RunMark
        switch evaluation.state {
        case .ok, .failed:
            guard let date = evaluation.expectedRun ?? record.lastRun else { return runs }
            mark = RunMark(date: date, outcome: evaluation.state == .ok ? .ok : .failed)
        case .missed:
            mark = RunMark(date: evaluation.expectedRun ?? record.stateSince, outcome: .missed)
        case .running, .waiting, .stale, .unknown, .hostOffline:
            return runs
        }
        var runs = runs
        if let last = runs.last, abs(mark.date.timeIntervalSince(last.date)) <= JobEvaluator.tolerance {
            runs[runs.count - 1].outcome = mark.outcome
        } else if runs.last.map({ mark.date > $0.date }) ?? true {
            runs.append(mark)
        }
        return Array(runs.suffix(limit))
    }
}
