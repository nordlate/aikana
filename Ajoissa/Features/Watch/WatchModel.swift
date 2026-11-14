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
        /// The end of a log file on a machine.
        var readLog: @Sendable (String, WatchedHost) async -> LogText
        /// Shows one notification.
        var deliver: @Sendable (Announcement) async -> Void
        /// Asks whether notifications may be shown; `false` when the user has said no.
        var requestNotificationPermission: @Sendable () async -> Bool
        /// A switch the user set, by name; `nil` when it was never set.
        var readSwitch: @Sendable (String) -> Bool?
        var writeSwitch: @Sendable (String, Bool) -> Void
    }

    /// The names the user's switches are stored under.
    enum SwitchName {
        static let notifications = "notificationsEnabled"
        static let recoveryNotifications = "recoveryNotificationsEnabled"
    }

    /// How often every job is looked at.
    static let lookInterval: Duration = .seconds(60)
    /// How often the config file is checked for a change.
    static let configCheckInterval: Duration = .seconds(2)

    private(set) var content: Content = .starting
    private(set) var lastLooked: Date?
    private(set) var isLooking = false
    /// When the look that is under way began. A look that never comes back is then seen to be old.
    private(set) var lookingSince: Date?
    /// Set when what was seen could not be written to the history file.
    private(set) var saveProblem: String?

    /// The job whose detail is shown in place of the list.
    var shownJobID: String?
    /// Whether problems are told with a system notification.
    var notificationsEnabled: Bool {
        didSet {
            environment.writeSwitch(SwitchName.notifications, notificationsEnabled)
            if notificationsEnabled, !oldValue {
                Task { await askForNotificationPermission() }
            }
        }
    }
    /// Whether a job that is fine again is told too.
    var notifiesRecovery: Bool {
        didSet { environment.writeSwitch(SwitchName.recoveryNotifications, notifiesRecovery) }
    }
    /// Whether the user has told macOS not to let Ajoissa show notifications.
    private(set) var notificationsRefused = false

    let configURL: URL
    let historyURL: URL

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var lookAgain = false
    @ObservationIgnored private var lastFingerprint: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// What was last told about each job since the app started. When the history cannot be saved, the same
    /// alert comes back at every look; this keeps it from being told again.
    @ObservationIgnored private var lastTold: [String: Alert.Kind] = [:]

    init(environment: Environment) {
        self.environment = environment
        configURL = environment.configURL
        historyURL = environment.historyURL
        notificationsEnabled = environment.readSwitch(SwitchName.notifications) ?? true
        notifiesRecovery = environment.readSwitch(SwitchName.recoveryNotifications) ?? true
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
            lookingSince = Date()
            lookAgain = false
            // The fingerprint is taken before the round, so a change made during it is noticed afterwards.
            lastFingerprint = environment.configFingerprint()
            let outcome = await environment.round(Date())
            apply(outcome)
            await announce(outcome)
        } while lookAgain
        isLooking = false
        lookingSince = nil
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
        if notificationsEnabled {
            Task { await askForNotificationPermission() }
        }
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

    /// The end of a log of the job with this id, read on the machine the job runs on.
    func logText(at path: String, ofJobWithID id: String) async -> LogText {
        guard let host = host(ofJobWithID: id) else { return .missing }
        return await environment.readLog(path, host)
    }

    /// Whether the job runs on this Mac, so that its files can be opened here.
    func isLocal(jobWithID id: String) -> Bool {
        host(ofJobWithID: id)?.connection == .local
    }

    private func host(ofJobWithID id: String) -> WatchedHost? {
        guard case let .jobs(groups) = content else { return nil }
        return groups.first { $0.reports.contains { $0.id == id } }?.host
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
        case let .looked(config, reports, _, problem):
            content = .jobs(HostGroup.groups(of: reports, hosts: config.hosts))
            if let shown = shownJobID, !reports.contains(where: { $0.id == shown }) {
                // A job that left the config must not open by itself if it comes back.
                shownJobID = nil
            }
            saveProblem = problem.map(Self.describe)
        }
    }

    // MARK: - Telling

    /// Shows the job's detail the next time the panel is looked at.
    func showJob(withID id: String?) {
        shownJobID = id
    }

    func askForNotificationPermission() async {
        notificationsRefused = await !environment.requestNotificationPermission()
    }

    /// Tells the user what the look found worth telling, as one notification.
    ///
    /// With notifications switched off nothing is told, and what would have been told is not kept for later:
    /// switching them on again must not bring up old news.
    private func announce(_ outcome: WatchSession.Outcome) async {
        guard case let .looked(_, reports, alerts, _) = outcome else { return }
        // What was told stands only while the job is still as it was told. Anything else ends it, also
        // when no alert said so: a job taken out of the config, or one set not to notify for a while.
        let states = Dictionary(reports.filter(\.job.notify).map { ($0.id, $0.state) }) { first, _ in first }
        lastTold = lastTold.filter { jobID, kind in
            switch kind {
            case let .problem(state): states[jobID] == state
            case .recovered: states[jobID] == .ok
            }
        }
        let new = alerts.filter { lastTold[$0.jobID] != $0.kind }
        for alert in new {
            lastTold[alert.jobID] = alert.kind
        }
        guard notificationsEnabled else { return }
        let wanted = new.filter { notifiesRecovery || $0.kind != .recovered }
        if let announcement = Announcement(alerts: wanted) {
            await environment.deliver(announcement)
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

    /// How long a look may take before the panel says that it is still under way.
    static let slowLook: TimeInterval = 120

    /// When the latest look was, or that one has been under way for long: a look can wait on a disk that
    /// does not answer, and what is shown is then older than it seems.
    func lookNote(now: Date = Date()) -> String? {
        if let lookingSince, now.timeIntervalSince(lookingSince) >= Self.slowLook {
            return "Still looking since \(Wording.moment(lookingSince, now: now)); what is shown may be out of date"
        }
        return lastLooked.map { "Looked at \(Wording.moment($0, now: now))" }
    }

    /// The menu bar symbol. A config or history that cannot be used, or a history that cannot be saved, needs
    /// attention as much as a job does.
    var menuBarSymbolName: String {
        switch content {
        case .starting:
            "clock"
        case .configProblem, .historyProblem:
            "clock.badge.exclamationmark"
        case .jobs:
            switch OverallStatus(reports: reports) {
            case .allFine: saveProblem == nil ? "clock.badge.checkmark" : "clock.badge.exclamationmark"
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
            let attention = reports.count(where: \.needsAttention)
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
