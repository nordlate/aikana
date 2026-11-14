import Foundation

extension SourceEvidence {
    /// What a launchd observation means for the evaluation.
    ///
    /// - Parameter logModified: When the job's log file was last written, if it has one and it could be read.
    public init(launchd observation: LaunchdObservation, logModified: Date? = nil) {
        // A plist that was found but not understood leaves the timetable unknown, which is different from a job
        // that is known to have none.
        let timetable = observation.definition.map(Timetable.init(definition:))
        switch observation.status {
        case let .loaded(state):
            self.init(
                availability: .available,
                timetable: timetable,
                isRunning: state.runState.map { $0 == .running },
                runCount: state.runs,
                lastExit: state.lastExit.map(RunExit.init(launchd:)),
                logModified: logModified
            )
        case .notLoaded:
            self.init(availability: .notLoaded, timetable: timetable, logModified: logModified)
        case .plistMissing:
            self.init(availability: .missing)
        case let .unknown(reason):
            self.init(availability: .unknown(reason: reason), timetable: timetable)
        }
    }
}

extension RunExit {
    init(launchd exit: LaunchdServiceState.LastExit) {
        switch exit {
        case .neverExited: self = .neverExited
        case let .code(code): self = .code(code)
        case let .signal(signal): self = .signal(signal)
        }
    }
}

extension LaunchdObservation {
    /// The files the job writes its output to: what launchd says it uses, or else what the plist says.
    public var logPaths: [String] {
        var paths: [String?] = []
        if case let .loaded(state) = status {
            paths += [state.standardOutPath, state.standardErrorPath]
        }
        paths += [definition?.standardOutPath, definition?.standardErrorPath]
        return paths.compactMap { $0 }.reduce(into: []) { unique, path in
            if !unique.contains(path) {
                unique.append(path)
            }
        }
    }
}
