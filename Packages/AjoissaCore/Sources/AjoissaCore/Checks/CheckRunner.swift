import Foundation

/// What a set of checks is run against.
public struct CheckContext: Sendable {
    public var now: Date
    /// The moment "since the last expected run" means for files: see ``JobEvaluation/checksSince``.
    /// `nil` for a job with no run to expect.
    public var since: Date?
    /// The moment that tells this run's output from the last one's: see ``JobEvaluation/outputSince``.
    public var outputSince: Date?
    /// Whether text found in the log can show that the expected run happened. It can for a run with a
    /// scheduled time; for a job on an interval the log is only read once a run has been seen anyway.
    public var logProvesRun: Bool
    /// Whether the expected run has not been seen yet. Commands are then left for later: a command judges what
    /// a run left behind, and cannot show that there was one.
    public var runIsOpen: Bool
    /// The scheduled time before the run in question: see ``JobEvaluation/runBeforeExpected``.
    public var runBefore: Date?
    /// A command result from before this moment is not reused once the moment has passed: see
    /// ``JobEvaluation/checksFreshFrom``.
    public var commandsFreshFrom: Date?
    /// The job's own log files, for a `log-pattern` check that names none.
    public var defaultLogPaths: [String]
    /// The calendar and time zone that times in messages are written in.
    public var calendar: Calendar

    public init(
        now: Date,
        since: Date?,
        outputSince: Date? = nil,
        logProvesRun: Bool = true,
        runIsOpen: Bool = false,
        runBefore: Date? = nil,
        commandsFreshFrom: Date? = nil,
        defaultLogPaths: [String] = [],
        calendar: Calendar
    ) {
        self.now = now
        self.since = since
        self.outputSince = outputSince ?? since
        self.logProvesRun = logProvesRun
        self.runIsOpen = runIsOpen
        self.runBefore = runBefore
        self.commandsFreshFrom = commandsFreshFrom
        self.defaultLogPaths = defaultLogPaths
        self.calendar = calendar
    }
}

/// Carries out a job's outcome checks on the machine the job runs on.
///
/// A check passes, fails (what it looked for is not there), could not be carried out, or was left for later.
/// "Could not be carried out" is never reported as a failure: not being able to look says nothing about the job.
public enum CheckRunner {
    /// How much of a log is read at most. A run that wrote more is judged by the end of what it wrote.
    static let logReadLimit: Int64 = 1_000_000
    /// How many bytes before a place in a log are remembered, to notice that the log was rewritten.
    static let tailLength: Int64 = 64
    /// How much of a command's output is kept to show.
    static let detailLimit = 2000
    /// How long a command's result is kept for the same run before the command is run again.
    static let commandRecheckInterval: TimeInterval = 15 * 60

    /// - Parameter state: What the checks remembered from the last time, or `nil` the first time.
    /// - Returns: One outcome per check, in order, and the state to remember for next time.
    public static func run(
        _ checks: [Check],
        on host: any HostAccess,
        context: CheckContext,
        state: CheckState?
    ) -> (outcomes: [CheckOutcome], state: CheckState) {
        var pass = CheckPass(host: host, context: context, previous: state ?? CheckState())
        let outcomes = checks.enumerated().map { pass.run($0.element, index: $0.offset) }
        return (outcomes, pass.state)
    }
}

struct CheckPass {
    let host: any HostAccess
    let context: CheckContext
    let previous: CheckState
    /// The state to keep: only what this pass looked at.
    var state = CheckState()
    /// What each log had new, so a log used by two checks is read and noted once.
    var logsRead: [String: LogReading] = [:]

    init(host: any HostAccess, context: CheckContext, previous: CheckState) {
        self.host = host
        self.context = context
        self.previous = previous
    }

    mutating func run(_ check: Check, index: Int) -> CheckOutcome {
        switch check {
        case let .fileAge(path, maxAge):
            fileAge(path: path, maxAge: maxAge)
        case let .fileSize(path, minBytes):
            fileSize(path: path, minBytes: minBytes)
        case let .command(arguments, timeout):
            command(arguments: arguments, timeout: timeout, index: index)
        case let .logPattern(path, contains, notContains):
            logPattern(path: path, contains: contains, notContains: notContains)
        }
    }

    // MARK: - file-age and file-size

    private func fileAge(path: String, maxAge: TimeInterval?) -> CheckOutcome {
        let newest: HostFile
        switch newestFile(matching: path) {
        case let .none(outcome): return outcome
        case let .file(file): newest = file
        }
        let threshold: Date
        let wanted: String
        if let maxAge {
            threshold = context.now.addingTimeInterval(-maxAge)
            wanted = "less than \(LaunchdJobDefinition.compact(seconds: Int(maxAge))) old"
        } else if let since = context.since {
            // A file is stamped by the machine that wrote it; allow for clocks that differ a little.
            threshold = since.addingTimeInterval(-JobEvaluator.tolerance)
            wanted = "newer than \(stamp(since))"
        } else {
            return CheckOutcome(result: .couldNotRun("\(path) has no expected run to be compared with; give the check a maxAge"))
        }
        guard newest.modified >= threshold else {
            return CheckOutcome(result: .failed("no file matching \(path) is \(wanted); the newest was written at \(stamp(newest.modified))"))
        }
        // Only "newer than the scheduled time" shows that this run happened, and it happened when the file
        // was written. "Less than a day old" shows nothing about a particular run.
        return CheckOutcome(
            result: .passed,
            provesRunAt: maxAge == nil ? newest.modified : nil,
            detail: "\(newest.path) was written at \(stamp(newest.modified))"
        )
    }

    private func fileSize(path: String, minBytes: Int64) -> CheckOutcome {
        let newest: HostFile
        switch newestFile(matching: path) {
        case let .none(outcome): return outcome
        case let .file(file): newest = file
        }
        guard newest.size >= minBytes else {
            return CheckOutcome(result: .failed("\(newest.path) is \(Self.bytes(newest.size)), less than the \(Self.bytes(minBytes)) it should be"))
        }
        return CheckOutcome(result: .passed, detail: "\(newest.path) is \(Self.bytes(newest.size))")
    }

    private enum Newest {
        case file(HostFile)
        /// There is no file to judge; this is the check's outcome.
        case none(CheckOutcome)
    }

    /// The most recently written file a path matches, or the outcome that says why there is none.
    private func newestFile(matching path: String) -> Newest {
        let files: [HostFile]
        do {
            files = try host.files(matching: path)
        } catch {
            return .none(CheckOutcome(result: .couldNotRun(error.message)))
        }
        guard !files.isEmpty else {
            return .none(CheckOutcome(result: .failed("no file matches \(path)")))
        }
        // A file stamped in the future is a clock problem. It must not count as newer than everything.
        let latestBelievable = context.now.addingTimeInterval(JobEvaluator.tolerance)
        guard let newest = files.filter({ $0.modified <= latestBelievable }).max(by: { $0.modified < $1.modified }) else {
            // With every clock reading wrong there is nothing to compare. That is not the job's failure.
            return .none(CheckOutcome(result: .couldNotRun("every file matching \(path) is stamped in the future, so their ages cannot be told")))
        }
        return .file(newest)
    }

    // MARK: - command

    private mutating func command(arguments: [String], timeout: TimeInterval, index: Int) -> CheckOutcome {
        // The place in the list is part of the key, so the same command given twice is kept twice.
        let key = "\(index) " + arguments.joined(separator: " ")
        if context.runIsOpen {
            state.commands[key] = previous.commands[key]
            return CheckOutcome(result: .skipped("it is run once the job has run"))
        }
        if let kept = previous.commands[key], kept.since == context.outputSince, !isFromBeforeTheRunHadItsTime(kept) {
            // A result stamped later than now is from before the clock was set back; it is not reused.
            let age = context.now.timeIntervalSince(kept.checkedAt)
            if age >= 0, age < CheckRunner.commandRecheckInterval {
                // Nothing has run since the command last judged this run. Asking again so soon would only
                // run the user's program every time Ajoissa looks.
                state.commands[key] = kept
                return kept.outcome
            }
        }
        let outcome = runCommand(arguments: arguments, timeout: timeout)
        state.commands[key] = CheckState.CommandResult(since: context.outputSince, checkedAt: context.now, outcome: outcome)
        return outcome
    }

    /// For a job known only through its checks, a result from while the job could still have been working
    /// says nothing once that time is over.
    private func isFromBeforeTheRunHadItsTime(_ kept: CheckState.CommandResult) -> Bool {
        guard let freshFrom = context.commandsFreshFrom, context.now > freshFrom else { return false }
        return kept.checkedAt <= freshFrom
    }

    private func runCommand(arguments: [String], timeout: TimeInterval) -> CheckOutcome {
        let program = arguments.first ?? ""
        let result: CommandResult
        do {
            result = try host.run(arguments, timeout: timeout)
        } catch {
            switch error {
            case let .notStarted(reason):
                return CheckOutcome(result: .couldNotRun("\(program) could not be started: \(reason)"))
            case let .timedOut(after):
                // A command that hangs has not said no. It is unknown, not failed.
                return CheckOutcome(result: .couldNotRun("\(program) did not finish within \(LaunchdJobDefinition.compact(seconds: Int(after)))"))
            }
        }
        let output = Self.shortened(result.output + result.errorOutput)
        guard result.exitCode == 0 else {
            return CheckOutcome(result: .failed("\(program) exited with code \(result.exitCode)"), detail: output)
        }
        return CheckOutcome(result: .passed, detail: output)
    }

    // MARK: - Wording

    func stamp(_ date: Date) -> String {
        let parts = context.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    /// 1500 → "1.5 KB". Powers of 1000, as sizes are written in the config.
    static func bytes(_ count: Int64) -> String {
        guard count >= 1000 else { return "\(count) B" }
        var value = Double(count) / 1000
        var unit = "KB"
        for larger in ["MB", "GB"] where value >= 1000 {
            value /= 1000
            unit = larger
        }
        // One decimal, and none when it would be ".0".
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) \(unit)" : "\(rounded) \(unit)"
    }

    static func shortened(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= CheckRunner.detailLimit ? trimmed : String(trimmed.prefix(CheckRunner.detailLimit)) + "…"
    }
}
