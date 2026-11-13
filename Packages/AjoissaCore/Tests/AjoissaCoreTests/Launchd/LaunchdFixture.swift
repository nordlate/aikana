import AjoissaCore
import Foundation

/// Real `launchctl print` output, captured from throwaway jobs and stripped of everything personal.
enum LaunchdFixture: String {
    case agentRunning = "agent-running"
    case agentExit3 = "agent-exit-3"
    case agentSignal = "agent-signal"
    case agentNeverRun = "agent-never-run"
    case agentArgumentLooksLikeAKey = "agent-exit-1-argument-looks-like-a-key"
    case daemonRunning = "daemon-running"

    var text: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(rawValue).txt")
        // A missing fixture is a broken checkout; an empty string then fails the test that asked for it.
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// What `launchctl print` says, and how it exits, when the domain has no such job.
    static let notFound = CommandResult(
        exitCode: 113,
        output: "",
        errorOutput: "Bad request.\nCould not find service \"com.example.job\" in domain for user gui: 501\n"
    )
}

/// Stands in for `launchctl`: answers by the job it is asked about and remembers every call.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<CommandResult, CommandError>] = [:]
    private var recorded: [[String]] = []

    /// Each call as the executable followed by its arguments.
    var calls: [[String]] {
        lock.withLock { recorded }
    }

    /// Sets what to answer when the last argument is `target`. Anything else is answered as not found.
    func answer(_ target: String, with result: Result<CommandResult, CommandError>) {
        lock.withLock { answers[target] = result }
    }

    func answer(_ target: String, output: String) {
        answer(target, with: .success(CommandResult(exitCode: 0, output: output)))
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        let answer = lock.withLock {
            recorded.append([executable] + arguments)
            return answers[arguments.last ?? ""]
        }
        return try (answer ?? .success(LaunchdFixture.notFound)).get()
    }
}
