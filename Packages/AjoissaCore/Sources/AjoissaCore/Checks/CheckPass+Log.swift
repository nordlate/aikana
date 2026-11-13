import Foundation

/// What one look at a log found.
enum LogReading {
    /// What the run in question wrote, and when the log was last written.
    case text(String, modified: Date?)
    /// The log was first looked at after the run had written to it, so the run's part cannot be told from
    /// what was there before.
    case notReadYet
    case unreadable(HostAccessError)
}

extension CheckPass {
    mutating func logPattern(path: String?, contains: String?, notContains: String?) -> CheckOutcome {
        let paths = path.map { [$0] } ?? context.defaultLogPaths
        guard !paths.isEmpty else {
            return CheckOutcome(result: .couldNotRun("the job has no log file of its own; give the check a path"))
        }
        guard let since = context.outputSince else {
            return CheckOutcome(result: .couldNotRun("the log has no expected run to be read from"))
        }
        // Every log is looked at before anything is decided, so that each one's end is noted for next time.
        let readings = paths.map { (path: $0, reading: reading(of: $0, since: since)) }
        var texts: [String] = []
        var notReadYet: String?
        var lastWritten: Date?
        for (path, reading) in readings {
            switch reading {
            case let .unreadable(error):
                return CheckOutcome(result: .couldNotRun(error.message))
            case .notReadYet:
                notReadYet = notReadYet ?? path
            case let .text(text, modified):
                texts.append(text)
                lastWritten = [lastWritten, modified].compactMap { $0 }.max()
            }
        }
        // Each log's text is kept apart, so that the end of one and the start of the next never form a match.
        if let notContains, let line = texts.lazy.compactMap({ Self.firstLine(of: $0, containing: notContains) }).first {
            return CheckOutcome(result: .failed("the log contains \"\(notContains)\""), detail: Self.shortened(line))
        }
        if let path = notReadYet {
            // Like a run from before the watch began, this run is not judged. What could be read had nothing
            // unwanted in it.
            return CheckOutcome(result: .passed, detail: "not read yet: \(path) is read from the next run on")
        }
        if let contains, !texts.contains(where: { $0.contains(contains) }) {
            return CheckOutcome(result: .failed("the log does not contain \"\(contains)\" since \(stamp(since))"))
        }
        // Text that had to be written since the scheduled time shows the job ran, when the log was written.
        // Text that is absent shows nothing.
        return CheckOutcome(result: .passed, provesRunAt: contains != nil && context.logProvesRun ? lastWritten : nil)
    }

    /// What was written to a log since the run identified by `since`. Also notes where the log ends now.
    private mutating func reading(of path: String, since: Date) -> LogReading {
        if let known = logsRead[path] {
            return known
        }
        let reading: LogReading
        do {
            reading = try read(path, since: since)
        } catch {
            reading = .unreadable(error)
        }
        logsRead[path] = reading
        return reading
    }

    private mutating func read(_ path: String, since: Date) throws(HostAccessError) -> LogReading {
        let file = try host.file(at: path)
        let size = file?.size ?? 0
        let end = try position(in: path, at: size, identity: file?.identity)
        state.logMarks[path] = CheckState.LogMark(position: end, date: context.now)

        guard var start = startOfRun(in: path, since: since, file: file, end: end) else {
            return .notReadYet
        }
        if try !stillHolds(start, in: path, file: file) {
            // The log is not the text it was: emptied, rewritten or replaced. All of it is new.
            start = CheckState.LogPosition(offset: 0, identity: file?.identity, noted: context.now)
        }
        state.logBaselines[path] = CheckState.LogBaseline(since: since, position: start)
        let from = max(start.offset, size - CheckRunner.logReadLimit)
        let data = try host.read(path, range: from..<size)
        // Bytes that are not valid text become replacement characters; one bad byte must not turn every
        // accented letter in the log into something a pattern cannot find.
        // swiftlint:disable:next optional_data_string_conversion
        return .text(String(decoding: data, as: UTF8.self), modified: file?.modified)
    }

    /// Where in the log the output of the run identified by `since` starts, or `nil` if that is not known.
    private func startOfRun(in path: String, since: Date, file: HostFile?, end: CheckState.LogPosition) -> CheckState.LogPosition? {
        if let kept = previous.logBaselines[path], kept.since == since {
            return kept.position
        }
        // Something noted before the previous scheduled time is from before an older run still. Reading from
        // there would take that run's output for this one's.
        let earliestUsable = context.runBefore ?? .distantPast
        if let mark = previous.logMarks[path], mark.date <= since, mark.date >= earliestUsable {
            // The last look was before the run: where the log ended then is where the run's output starts.
            return mark.position
        }
        if file.map({ $0.modified < since.addingTimeInterval(-JobEvaluator.tolerance) }) ?? true {
            // Never looked before the run, but the log has not been written since: nothing in it is new.
            return end
        }
        if let kept = previous.logBaselines[path], kept.since < since, kept.since >= earliestUsable {
            // The start of an earlier run is known. Reading from there takes in more than this run wrote,
            // which is better than not reading it at all.
            return kept.position
        }
        return nil
    }

    /// A place in the log as it is now: the offset, the file's identity and the bytes just before the offset.
    private func position(in path: String, at offset: Int64, identity: UInt64?) throws(HostAccessError) -> CheckState.LogPosition {
        let tail = try host.read(path, range: max(0, offset - CheckRunner.tailLength)..<offset)
        return CheckState.LogPosition(offset: offset, identity: identity, tail: tail, noted: context.now)
    }

    /// Whether a remembered place still means the same text: the log is at least that long, is the same file,
    /// still has the same bytes before that place, and has not been written without growing.
    private func stillHolds(_ position: CheckState.LogPosition, in path: String, file: HostFile?) throws(HostAccessError) -> Bool {
        let size = file?.size ?? 0
        if position.offset > size {
            return false
        }
        if let then = position.identity, let now = file?.identity, then != now {
            return false
        }
        if position.offset == size, let noted = position.noted, let modified = file?.modified, modified > noted {
            // Written since, yet exactly as long as it was: rewritten with text of the same length. A job that
            // empties its log and writes the same lines every run does this.
            return false
        }
        guard !position.tail.isEmpty else { return true }
        let before = Int64(position.tail.count)
        return try host.read(path, range: (position.offset - before)..<position.offset) == position.tail
    }

    static func firstLine(of text: String, containing needle: String) -> String? {
        guard text.contains(needle) else { return nil }
        return text.split(whereSeparator: \.isNewline).first { $0.contains(needle) }.map(String.init) ?? needle
    }
}
