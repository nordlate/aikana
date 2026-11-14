import Foundation

/// Something about one job that is worth telling the user once.
public struct Alert: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The job has a problem the user has not been told about: `failed`, `missed` or `stale`.
        case problem(JobState)
        /// The job the user was told about is fine again.
        case recovered
    }

    public var kind: Kind
    public var jobID: String
    public var jobName: String
    public var hostID: String
    /// Why, as the evaluation worded it.
    public var reason: String

    public init(kind: Kind, jobID: String, jobName: String, hostID: String, reason: String) {
        self.kind = kind
        self.jobID = jobID
        self.jobName = jobName
        self.hostID = hostID
        self.reason = reason
    }
}

/// Decides what to tell the user after a look, so that each incident is told once.
///
/// An incident starts when a job is found `failed`, `missed` or `stale`, and ends when the job is `ok` again.
/// What the user was last told is kept in the job's record (``JobRecord/alerted``), so it holds across
/// restarts. States in between (`waiting`, `running`, `unknown`, `hostOffline`) neither start nor end an
/// incident: a failed job that is waiting for its next run has not recovered, and one that fails again
/// has not failed anew.
public enum AlertPlanner {
    /// - Parameter history: The records as the look left them. What is told now is noted in them.
    /// - Returns: The alerts for this look, problems first, each group in the order of `reports`.
    public static func plan(reports: [JobReport], history: inout History) -> [Alert] {
        var problems: [Alert] = []
        var recoveries: [Alert] = []
        for report in reports where report.isJudged {
            guard var record = history.jobs[report.id] else { continue }
            defer { history.jobs[report.id] = record }
            guard report.job.notify else {
                // Nothing is told about this job, so there is nothing to follow up on either.
                record.alerted = nil
                continue
            }
            if report.state.isProblem {
                if record.alerted != report.state {
                    record.alerted = report.state
                    problems.append(alert(.problem(report.state), report))
                }
            } else if report.state == .ok, record.alerted != nil {
                record.alerted = nil
                recoveries.append(alert(.recovered, report))
            }
        }
        return problems + recoveries
    }

    private static func alert(_ kind: Alert.Kind, _ report: JobReport) -> Alert {
        Alert(kind: kind, jobID: report.id, jobName: report.job.name, hostID: report.job.hostID, reason: report.reason)
    }
}

/// One notification: everything a look found worth telling, in a title and a few lines.
public struct Announcement: Sendable, Equatable {
    /// How many jobs are listed by name when there are several.
    public static let lineLimit = 4

    public var title: String
    public var body: String
    /// The job to show when the notification is clicked. `nil` when it is about several jobs.
    public var jobID: String?

    public init(title: String, body: String, jobID: String?) {
        self.title = title
        self.body = body
        self.jobID = jobID
    }

    /// The alerts of one look as one notification. `nil` when there are none.
    public init?(alerts: [Alert]) {
        guard let first = alerts.first else { return nil }
        if alerts.count == 1 {
            self.init(
                title: "\(first.jobName) \(first.kind.predicate)",
                body: "\(Host.displayName(ofID: first.hostID)): \(first.reason)",
                jobID: first.jobID
            )
            return
        }
        let problems = alerts.count { $0.kind != .recovered }
        let recoveries = alerts.count - problems
        let title: String
        if recoveries == 0 {
            title = "\(problems) jobs have problems"
        } else if problems == 0 {
            title = "\(recoveries) jobs are fine again"
        } else {
            title = [
                problems == 1 ? "1 job has a problem" : "\(problems) jobs have problems",
                recoveries == 1 ? "1 is fine again" : "\(recoveries) are fine again"
            ].joined(separator: ", ")
        }
        var lines = alerts.prefix(Self.lineLimit).map {
            "\($0.jobName) (\(Host.displayName(ofID: $0.hostID))) \($0.kind.predicate): \($0.reason)"
        }
        if alerts.count > Self.lineLimit {
            lines.append("and \(alerts.count - Self.lineLimit) more")
        }
        self.init(title: title, body: lines.joined(separator: "\n"), jobID: nil)
    }
}

extension Alert.Kind {
    /// What happened, as the end of a sentence that starts with the job's name.
    var predicate: String {
        switch self {
        case .problem(.missed): "missed a run"
        case .problem(.stale): "cannot be read"
        case .problem: "failed"
        case .recovered: "is fine again"
        }
    }
}

extension Host {
    /// The machine's name as it is shown: "This Mac" for the one Aikana runs on, else its id.
    public static func displayName(ofID id: String) -> String {
        id == localID ? "This Mac" : id
    }

    public var displayName: String {
        Self.displayName(ofID: id)
    }
}
