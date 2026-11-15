import Foundation

extension LaunchdObservation {
    /// The job's state in one line, such as "loaded, not running, 3 runs, last exit code 0".
    public var statusDescription: String {
        switch status {
        case let .loaded(state):
            (["loaded"] + state.descriptionParts).joined(separator: ", ")
        case .notLoaded:
            "not loaded: the plist exists but launchd has not loaded it, so the job will not run"
        case .plistMissing:
            "not found: there is no plist with this label and launchd does not know it"
        case let .unknown(reason):
            "unknown: \(reason)"
        }
    }

    /// The job's state in parts, each marked when it is a sign of trouble: "loaded, idle", "last exit 1",
    /// "41 runs".
    public var statusParts: [StatusPart] {
        switch status {
        case let .loaded(state):
            var parts = [StatusPart(state.runWords.map { "loaded, \($0)" } ?? "loaded")]
            switch state.lastExit {
            case .neverExited: parts.append(StatusPart("never exited"))
            case let .code(code): parts.append(StatusPart("last exit \(code)", isProblem: code != 0))
            case let .signal(signal): parts.append(StatusPart("ended by signal \(signal)", isProblem: true))
            case nil: break
            }
            if let runs = state.runs {
                parts.append(StatusPart(runs == 1 ? "1 run" : "\(runs) runs"))
            }
            return parts
        case .notLoaded:
            return [StatusPart("not loaded", isProblem: true)]
        case .plistMissing:
            return [StatusPart("not found", isProblem: true)]
        case let .unknown(reason):
            return [StatusPart("unknown: \(reason)")]
        }
    }

    /// The job's timetable in a few words, or why there is none to show.
    public var scheduleDescription: String {
        if let definitionProblem {
            return "unreadable: \(definitionProblem)"
        }
        guard let definition else {
            return "unknown: no plist was found"
        }
        return definition.scheduleDescription ?? "none: the job does not run on a timetable"
    }
}

private extension LaunchdServiceState {
    /// Whether the job is running, in a word or two.
    var runWords: String? {
        switch runState {
        case .running: processID.map { "running as process \($0)" } ?? "running"
        case .notRunning: "idle"
        case let .other(text): text
        case nil: nil
        }
    }

    var descriptionParts: [String] {
        var parts: [String] = []
        switch runState {
        case .running: parts.append(processID.map { "running as process \($0)" } ?? "running")
        case .notRunning: parts.append("not running")
        case let .other(text): parts.append(text)
        case nil: break
        }
        if let runs {
            parts.append(runs == 1 ? "1 run" : "\(runs) runs")
        }
        switch lastExit {
        case .neverExited: parts.append("never exited")
        case let .code(code): parts.append("last exit code \(code)")
        case let .signal(signal): parts.append("last run ended by signal \(signal)")
        case nil: break
        }
        return parts
    }
}
