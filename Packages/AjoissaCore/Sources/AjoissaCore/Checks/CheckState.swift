import Foundation

/// What the checks remember between evaluations.
///
/// A log file only grows, and nothing in it says which part belongs to which run. To look only at what a run
/// wrote, Ajoissa remembers how long each log was when it last looked, and from that where the log stood just
/// before the run in question.
public struct CheckState: Sendable, Equatable, Codable {
    /// How long a log was at a moment.
    public struct LogMark: Sendable, Equatable, Codable {
        public var size: Int64
        public var date: Date

        public init(size: Int64, date: Date) {
            self.size = size
            self.date = date
        }
    }

    /// Where a log stood just before a run: everything from `offset` on was written since.
    public struct LogBaseline: Sendable, Equatable, Codable {
        /// The moment the "since" in question starts, usually the scheduled time of the run.
        public var since: Date
        public var offset: Int64

        public init(since: Date, offset: Int64) {
            self.since = since
            self.offset = offset
        }
    }

    /// By log path: its length at the last look.
    public var logMarks: [String: LogMark]
    /// By log path: where it stood before the run that is being judged.
    public var logBaselines: [String: LogBaseline]

    public init(logMarks: [String: LogMark] = [:], logBaselines: [String: LogBaseline] = [:]) {
        self.logMarks = logMarks
        self.logBaselines = logBaselines
    }
}
