import AjoissaCore
import Foundation
import Observation

/// What the menu bar item and its panel show: the latest look at every job, kept current.
@MainActor
@Observable
final class WatchModel {
    enum Content: Equatable {
        /// The first look has not come back yet.
        case starting
        /// The config file cannot be used. One line per problem.
        case configProblem([String])
        /// The history file cannot be read.
        case historyProblem(String)
        case jobs([HostGroup])
    }

    /// What reading the end of a log came to.
    enum LogText: Equatable {
        case text(String)
        case missing
        case unreadable(String)
    }

    /// What the model needs from outside. Tests put their own in.
    struct Environment: Sendable {
        var configURL: URL
        var historyURL: URL
        /// One round: read the config and the history, look at every job, save.
        var round: @Sendable (Date) async -> WatchSession.Outcome
        /// Something that changes whenever the config file does.
        var configFingerprint: @Sendable () -> String
        var readLog: @Sendable (String) async -> LogText
    }

    /// How often every job is looked at.
    static let lookInterval: Duration = .seconds(60)
    /// How often the config file is checked for a change.
    static let configCheckInterval: Duration = .seconds(2)

    private(set) var content: Content = .starting
    private(set) var lastLooked: Date?
    private(set) var isLooking = false
    /// Set when what was seen could not be written to the history file.
    private(set) var saveProblem: String?

    let configURL: URL
    let historyURL: URL

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var lookAgain = false
    @ObservationIgnored private var lastFingerprint: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(environment: Environment) {
        self.environment = environment
        configURL = environment.configURL
        historyURL = environment.historyURL
    }

    // MARK: - Looking

    /// Looks at every job now. A request that arrives while a look is under way is answered by one more look
    /// after it, however many requests there were.
    func refresh() async {
        if isLooking {
            lookAgain = true
            return
        }
        isLooking = true
        repeat {
            lookAgain = false
            // The fingerprint is taken before the round, so a change made during it is noticed afterwards.
            lastFingerprint = environment.configFingerprint()
            apply(await environment.round(Date()))
        } while lookAgain
        isLooking = false
    }

    /// Looks again if the config file is not the one that was last read.
    func checkConfigFile() async {
        if environment.configFingerprint() != lastFingerprint {
            await refresh()
        }
    }

    /// Starts looking on a timer and watching the config file. `wakes` yields each time the Mac wakes.
    func start(wakes: AsyncStream<Void>) {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: Self.lookInterval)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.configCheckInterval)
                    await self?.checkConfigFile()
                }
            },
            Task { [weak self] in
                for await _ in wakes {
                    await self?.refresh()
                }
            }
        ]
    }

    func logText(at path: String) async -> LogText {
        await environment.readLog(path)
    }

    private func apply(_ outcome: WatchSession.Outcome) {
        lastLooked = Date()
        switch outcome {
        case let .configProblem(error):
            content = .configProblem(error.lines)
            saveProblem = nil
        case let .historyProblem(error):
            content = .historyProblem(Self.describe(error))
            saveProblem = nil
        case let .looked(config, reports, problem):
            content = .jobs(HostGroup.groups(of: reports, hosts: config.hosts))
            saveProblem = problem.map(Self.describe)
        }
    }

    private static func describe(_ error: HistoryError) -> String {
        switch error {
        case let .unreadable(path, reason):
            "\(path) cannot be used as the history: \(reason). Move it aside to start a new history; runs seen so far will then be forgotten."
        case let .unwritable(path, reason):
            "What was seen could not be saved to \(path): \(reason)"
        }
    }

    // MARK: - At a glance

    var reports: [JobReport] {
        if case let .jobs(groups) = content {
            return groups.flatMap(\.reports)
        }
        return []
    }

    func report(withID id: String) -> JobReport? {
        reports.first { $0.id == id }
    }

    /// The menu bar symbol. A config or history that cannot be used needs attention as much as a job does.
    var menuBarSymbolName: String {
        switch content {
        case .starting:
            "clock"
        case .configProblem, .historyProblem:
            "clock.badge.exclamationmark"
        case .jobs:
            switch OverallStatus(reports: reports) {
            case .allFine: "clock.badge.checkmark"
            case .needsAttention: "clock.badge.exclamationmark"
            case .failure: "clock.badge.xmark"
            }
        }
    }

    /// The state of everything in one line.
    var headline: String {
        switch content {
        case .starting:
            return "Looking…"
        case .configProblem:
            return "The config file cannot be used"
        case .historyProblem:
            return "The history file cannot be used"
        case .jobs:
            let reports = reports
            if reports.isEmpty {
                return "No jobs configured"
            }
            let failed = reports.count { $0.state == .failed }
            let attention = reports.count { [.missed, .stale, .hostOffline].contains($0.state) }
            var parts: [String] = []
            if failed > 0 {
                parts.append("\(failed) failed")
            }
            if attention > 0 {
                parts.append(attention == 1 ? "1 needs attention" : "\(attention) need attention")
            }
            return parts.isEmpty ? "Everything is fine" : parts.joined(separator: ", ")
        }
    }
}
