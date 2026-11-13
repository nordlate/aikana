import Foundation

/// Looks at every job in a config that runs on this Mac.
///
/// This gathers; ``JobAssessor`` judges. Jobs on other machines, and jobs of schedulers that are not read
/// yet, are reported as not judged.
public struct LocalWatch: Sendable {
    /// The moments the machine last woke and last started, as known at one look.
    public struct Uptime: Sendable, Equatable {
        public var awakeSince: Date?
        public var bootedAt: Date?

        public init(awakeSince: Date?, bootedAt: Date?) {
            self.awakeSince = awakeSince
            self.bootedAt = bootedAt
        }
    }

    private let collector: LaunchdCollector
    private let host: any HostAccess
    private let uptime: @Sendable () -> Uptime
    private let logModified: @Sendable ([String]) -> Date?

    /// - Parameters:
    ///   - uptime: Asked once per look.
    ///   - logModified: When the newest of some log files was last written.
    public init(
        collector: LaunchdCollector,
        host: any HostAccess,
        uptime: @escaping @Sendable () -> Uptime,
        logModified: @escaping @Sendable ([String]) -> Date?
    ) {
        self.collector = collector
        self.host = host
        self.uptime = uptime
        self.logModified = logModified
    }

    /// The watch on the Mac this runs on, for the user with this home directory.
    public init(homeDirectory: URL, userID: UInt32) {
        let runner = ProcessCommandRunner()
        self.init(
            collector: LaunchdCollector(
                runner: runner,
                locations: LaunchdSearchLocation.standard(homeDirectory: homeDirectory, userID: userID)
            ),
            host: LocalHost(homeDirectory: homeDirectory, runner: runner),
            uptime: { Uptime(awakeSince: SystemUptime.awakeSince(), bootedAt: SystemUptime.bootedAt()) },
            logModified: { FileTimes.latestModification(of: $0) }
        )
    }

    /// Looks at each job once.
    ///
    /// - Parameter history: What was remembered. It is updated with what this look found, and the records of
    ///   jobs that are no longer in the config are dropped.
    /// - Returns: One report per job, in the order of the config.
    public func look(at config: Config, history: inout History, now: Date, calendar: Calendar) -> [JobReport] {
        let uptime = uptime()
        let reports = config.jobs.map { job in
            let (report, record) = look(at: job, previous: history.jobs[job.id], uptime: uptime, now: now, calendar: calendar)
            if let record {
                history.jobs[job.id] = record
            }
            return report
        }
        history.keepOnly(jobIDs: config.jobs.map(\.id))
        return reports
    }

    private func look(
        at job: Job,
        previous: JobRecord?,
        uptime: Uptime,
        now: Date,
        calendar: Calendar
    ) -> (JobReport, JobRecord?) {
        guard job.hostID == Host.localID else {
            return (Self.notJudged(job, "only jobs on this Mac are supported so far"), nil)
        }
        var evidence = Evidence(awakeSince: uptime.awakeSince, bootedAt: uptime.bootedAt)
        var report = JobReport(job: job, state: .unknown, reason: "", schedule: job.schedule?.summary ?? "")
        var logPaths: [String] = []
        switch job.source {
        case let .launchd(label):
            let observation = collector.observe(label: label)
            logPaths = observation.logPaths
            evidence.source = SourceEvidence(launchd: observation, logModified: logModified(logPaths))
            report.source = "launchd \(label)"
            report.sourceStatus = observation.statusDescription
            if job.schedule == nil {
                report.schedule = observation.scheduleDescription
            }
        case .systemd, .cron:
            return (Self.notJudged(job, "of the schedulers, only launchd is read so far"), nil)
        case nil:
            break
        }
        let assessment = JobAssessor.assess(
            job: job,
            evidence: evidence,
            host: host,
            defaultLogPaths: logPaths,
            previous: previous,
            now: now,
            calendar: calendar
        )
        let evaluation = assessment.evaluation
        report.state = evaluation.state
        report.reason = evaluation.reason
        report.lastRun = evaluation.record.lastRun
        report.nextRun = evaluation.nextRun
        report.checks = zip(job.checks, assessment.outcomes).map { JobReport.CheckReport(label: $0.label, outcome: $1) }
        report.transitions = evaluation.record.transitions
        report.logPaths = Self.unique(logPaths + job.checks.compactMap(\.logPath))
        report.changed = evaluation.changed
        return (report, evaluation.record)
    }

    private static func notJudged(_ job: Job, _ why: String) -> JobReport {
        JobReport(
            job: job,
            state: .unknown,
            reason: "not judged yet: \(why)",
            isJudged: false,
            schedule: job.schedule?.summary ?? ""
        )
    }

    private static func unique(_ paths: [String]) -> [String] {
        paths.reduce(into: []) { unique, path in
            if !unique.contains(path) {
                unique.append(path)
            }
        }
    }
}

private extension Check {
    /// The log a `log-pattern` check names itself.
    var logPath: String? {
        if case let .logPattern(path, _, _) = self {
            return path
        }
        return nil
    }
}
