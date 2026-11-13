import Foundation

/// What a set of checks is run against.
public struct CheckContext: Sendable {
    public var now: Date
    /// The moment "since the last expected run" means: the scheduled time of the run being judged.
    /// `nil` for a job with no run to expect.
    public var since: Date?
    /// The job's own log files, for a `log-pattern` check that names none.
    public var defaultLogPaths: [String]
    /// The calendar and time zone that times in messages are written in.
    public var calendar: Calendar

    public init(now: Date, since: Date?, defaultLogPaths: [String] = [], calendar: Calendar) {
        self.now = now
        self.since = since
        self.defaultLogPaths = defaultLogPaths
        self.calendar = calendar
    }
}

/// Carries out a job's outcome checks on the machine the job runs on.
///
/// A check has three results. It passes, it fails (what it looked for is not there), or it could not be
/// carried out. The last is never reported as a failure: not being able to look says nothing about the job.
public enum CheckRunner {
    /// How much of a log is read at most. A run that wrote more is judged by the end of what it wrote.
    static let logReadLimit = 1_000_000
    /// How much of a command's output is kept to show.
    static let detailLimit = 2000

    /// - Parameter state: What the checks remembered from the last time, or `nil` the first time.
    /// - Returns: One outcome per check, in order, and the state to remember for next time.
    public static func run(
        _ checks: [Check],
        on host: any HostAccess,
        context: CheckContext,
        state: CheckState?
    ) -> (outcomes: [CheckOutcome], state: CheckState) {
        var pass = CheckPass(host: host, context: context, previous: state ?? CheckState())
        let outcomes = checks.map { pass.run($0) }
        return (outcomes, pass.state)
    }
}

struct CheckPass {
    let host: any HostAccess
    let context: CheckContext
    let previous: CheckState
    /// The state to keep: only the logs this pass looked at.
    var state = CheckState()
    /// What each log had new, so a log used by two checks is read and marked once.
    var newLogText: [String: Result<String?, HostAccessError>] = [:]

    init(host: any HostAccess, context: CheckContext, previous: CheckState) {
        self.host = host
        self.context = context
        self.previous = previous
    }

    mutating func run(_ check: Check) -> CheckOutcome {
        switch check {
        case let .fileAge(path, maxAge):
            fileAge(path: path, maxAge: maxAge)
        case let .fileSize(path, minBytes):
            fileSize(path: path, minBytes: minBytes)
        case let .command(arguments, timeout):
            command(arguments: arguments, timeout: timeout)
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
        // Only "newer than the scheduled time" shows that this run happened. "Less than a day old" does not.
        return CheckOutcome(result: .passed, provesRun: maxAge == nil, detail: "\(newest.path) was written at \(stamp(newest.modified))")
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
        // A file stamped in the future is a clock problem. It must not count as newer than everything.
        let latestBelievable = context.now.addingTimeInterval(JobEvaluator.tolerance)
        guard let newest = files.filter({ $0.modified <= latestBelievable }).max(by: { $0.modified < $1.modified }) else {
            return .none(CheckOutcome(result: .failed(files.isEmpty ? "no file matches \(path)" : "every file matching \(path) is stamped in the future")))
        }
        return .file(newest)
    }

    // MARK: - command

    private func command(arguments: [String], timeout: TimeInterval) -> CheckOutcome {
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

    // MARK: - log-pattern

    private mutating func logPattern(path: String?, contains: String?, notContains: String?) -> CheckOutcome {
        let paths = path.map { [$0] } ?? context.defaultLogPaths
        guard !paths.isEmpty else {
            return CheckOutcome(result: .couldNotRun("the job has no log file of its own; give the check a path"))
        }
        guard let since = context.since else {
            return CheckOutcome(result: .couldNotRun("the log has no expected run to be read from"))
        }
        // Every log is looked at before anything is decided, so that each one's length is noted for next time.
        let found = paths.map { (path: $0, text: newText(in: $0, since: since)) }
        var text = ""
        for (path, result) in found {
            switch result {
            case let .failure(error):
                return CheckOutcome(result: .couldNotRun(error.message))
            case .success(nil):
                // The log was first looked at after this run wrote to it, so the run's part cannot be told
                // from what was there before. Like a run from before the watch began, it is not judged.
                return CheckOutcome(result: .passed, detail: "not read yet: \(path) is read from the next run on")
            case let .success(new?):
                text += new
            }
        }
        if let notContains, let line = Self.firstLine(of: text, containing: notContains) {
            return CheckOutcome(result: .failed("the log contains \"\(notContains)\""), detail: Self.shortened(line))
        }
        if let contains, !text.contains(contains) {
            return CheckOutcome(result: .failed("the log does not contain \"\(contains)\" since \(stamp(since))"))
        }
        // Text that had to be written since the scheduled time shows the job ran. Text that is absent does not.
        return CheckOutcome(result: .passed, provesRun: contains != nil)
    }

    /// What was written to a log since `since`, and a note of how long the log is now. `nil` when it is not
    /// known where in the log `since` is.
    private mutating func newText(in path: String, since: Date) -> Result<String?, HostAccessError> {
        if let known = newLogText[path] {
            return known
        }
        let result: Result<String?, HostAccessError>
        do {
            result = .success(try readNewText(in: path, since: since))
        } catch {
            result = .failure(error)
        }
        newLogText[path] = result
        return result
    }

    private mutating func readNewText(in path: String, since: Date) throws(HostAccessError) -> String? {
        let file = try host.file(at: path)
        let size = file?.size ?? 0
        state.logMarks[path] = CheckState.LogMark(size: size, date: context.now)

        var baseline: CheckState.LogBaseline
        if let kept = previous.logBaselines[path], kept.since == since {
            baseline = kept
        } else if let mark = previous.logMarks[path], mark.date < since {
            // The last look was before the run: the log's length then is where the run's output starts.
            baseline = CheckState.LogBaseline(since: since, offset: mark.size)
        } else if file.map({ $0.modified < since.addingTimeInterval(-JobEvaluator.tolerance) }) ?? true {
            // Never looked before the run, but the log has not been written since: nothing in it is new.
            baseline = CheckState.LogBaseline(since: since, offset: size)
        } else {
            return nil
        }
        if baseline.offset > size {
            // The log is shorter than it was: it was emptied or replaced, so all of it is new.
            baseline.offset = 0
        }
        state.logBaselines[path] = baseline
        let data = try host.read(path, from: baseline.offset, limit: CheckRunner.logReadLimit)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Wording

    private func stamp(_ date: Date) -> String {
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

    static func firstLine(of text: String, containing needle: String) -> String? {
        guard text.contains(needle) else { return nil }
        return text.split(whereSeparator: \.isNewline).first { $0.contains(needle) }.map(String.init) ?? needle
    }
}
