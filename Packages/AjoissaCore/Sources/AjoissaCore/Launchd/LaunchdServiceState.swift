import Foundation

/// What launchd reports about a job it has loaded. A field is `nil` when the output did not say.
public struct LaunchdServiceState: Sendable, Equatable {
    public enum RunState: Sendable, Equatable {
        case running
        case notRunning
        /// A state Ajoissa does not know, as launchd words it.
        case other(String)
    }

    public enum LastExit: Sendable, Equatable {
        /// The job has not finished a run since it was loaded.
        case neverExited
        case code(Int)
        /// The last run was ended by a signal, as launchd words it: "Terminated: 15".
        case signal(String)
    }

    public var runState: RunState?
    public var processID: Int?
    /// How many times the job has started since it was loaded. Resets when the job is reloaded or the Mac restarts.
    public var runs: Int?
    public var lastExit: LastExit?
    /// The plist launchd loaded the job from.
    public var plistPath: String?
    public var standardOutPath: String?
    public var standardErrorPath: String?

    public init(
        runState: RunState? = nil,
        processID: Int? = nil,
        runs: Int? = nil,
        lastExit: LastExit? = nil,
        plistPath: String? = nil,
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil
    ) {
        self.runState = runState
        self.processID = processID
        self.runs = runs
        self.lastExit = lastExit
        self.plistPath = plistPath
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
    }
}

/// Reads the output of `launchctl print <domain>/<label>`.
///
/// Apple documents this output as not stable, so the parser takes only what it recognises and leaves the rest
/// `nil`. It never fails on a line it does not know. When the format changes, update it here and add a fixture.
enum LaunchctlPrintParser {
    /// - Returns: `nil` when the text does not look like the description of a service at all.
    static func parse(_ output: String) -> LaunchdServiceState? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, header.hasSuffix(" = {"), !header.hasPrefix("\t") else { return nil }

        var state = LaunchdServiceState()
        var insideBlock = false
        for line in lines.dropFirst() {
            // The service's own settings are indented by exactly one tab. Deeper lines belong to a nested block
            // such as the arguments or the environment, whose contents can look like settings and must be skipped.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            if insideBlock {
                insideBlock = line != "\t}"
                continue
            }
            if line.hasSuffix(" = {") || line.hasSuffix(" => {") {
                insideBlock = true
                continue
            }
            guard let separator = line.range(of: " = ") else { continue }
            apply(key: line[line.index(after: line.startIndex)..<separator.lowerBound], value: line[separator.upperBound...], to: &state)
        }
        return state
    }

    private static func apply(key: Substring, value: Substring, to state: inout LaunchdServiceState) {
        switch key {
        case "state":
            state.runState = state.runState ?? runState(value)
        case "pid":
            state.processID = state.processID ?? Int(value)
        case "runs":
            state.runs = state.runs ?? Int(value)
        case "last exit code":
            state.lastExit = state.lastExit ?? lastExitCode(value)
        case "last terminating signal":
            state.lastExit = state.lastExit ?? .signal(String(value))
        case "path":
            state.plistPath = state.plistPath ?? String(value)
        case "stdout path":
            state.standardOutPath = state.standardOutPath ?? String(value)
        case "stderr path":
            state.standardErrorPath = state.standardErrorPath ?? String(value)
        default:
            break
        }
    }

    private static func runState(_ value: Substring) -> LaunchdServiceState.RunState {
        switch value {
        case "running": .running
        case "not running": .notRunning
        default: .other(String(value))
        }
    }

    /// "0", "(never exited)", or a code followed by its name, as in "78: EX_CONFIG".
    private static func lastExitCode(_ value: Substring) -> LaunchdServiceState.LastExit? {
        if value == "(never exited)" {
            return .neverExited
        }
        return Int(value.prefix { $0.isASCII && ($0.isNumber || $0 == "-") }).map { .code($0) }
    }
}
