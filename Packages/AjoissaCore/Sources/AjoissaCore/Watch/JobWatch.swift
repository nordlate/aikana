import Foundation

/// Looks at every job in a config, on this Mac and on the machines it reaches over SSH.
///
/// This gathers; ``JobAssessor`` judges. Jobs of schedulers that are not read yet are reported as not judged.
public struct JobWatch: Sendable {
    /// The moments a machine last woke and last started, as known at one look.
    public struct Uptime: Sendable, Equatable {
        public var awakeSince: Date?
        public var bootedAt: Date?

        public init(awakeSince: Date?, bootedAt: Date?) {
            self.awakeSince = awakeSince
            self.bootedAt = bootedAt
        }
    }

    /// How far another machine's clock may be from this Mac's. Beyond that, what it says about when things
    /// happened cannot be compared with when they were due.
    public static let clockTolerance: TimeInterval = 120

    private let collector: LaunchdCollector
    private let host: any HostAccess
    private let uptime: @Sendable () -> Uptime
    private let remoteShell: @Sendable (_ alias: String) -> RemoteShell
    private let remoteLaunchctlPath: String

    /// - Parameters:
    ///   - collector: Reads launchd on this Mac.
    ///   - host: This Mac, for checks.
    ///   - uptime: This Mac's. Asked once per look.
    ///   - remoteShell: The shell on the machine an SSH alias names.
    ///   - remoteLaunchctlPath: Where `launchctl` is on other Macs. Tests put a stand-in here.
    public init(
        collector: LaunchdCollector,
        host: any HostAccess,
        uptime: @escaping @Sendable () -> Uptime,
        remoteShell: @escaping @Sendable (_ alias: String) -> RemoteShell,
        remoteLaunchctlPath: String = LaunchdCollector.launchctl
    ) {
        self.collector = collector
        self.host = host
        self.uptime = uptime
        self.remoteShell = remoteShell
        self.remoteLaunchctlPath = remoteLaunchctlPath
    }

    /// The watch from the Mac this runs on, for the user with this home directory.
    ///
    /// - Parameter controlDirectory: A private folder for the sockets that let the scripts sent to one
    ///   machine share a connection. It is created if needed. `nil` means a connection per script.
    public init(homeDirectory: URL, userID: UInt32, controlDirectory: URL?) {
        let runner = ProcessCommandRunner()
        if let controlDirectory {
            // Only the user may use the sockets in it.
            try? FileManager.default.createDirectory(
                at: controlDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        self.init(
            collector: LaunchdCollector(
                runner: runner,
                locations: LaunchdSearchLocation.standard(homeDirectory: homeDirectory, userID: userID)
            ),
            host: LocalHost(homeDirectory: homeDirectory, runner: runner),
            uptime: { Uptime(awakeSince: SystemUptime.awakeSince(), bootedAt: SystemUptime.bootedAt()) },
            remoteShell: { RemoteShell.ssh(alias: $0, runner: runner, controlDirectory: controlDirectory) }
        )
    }

    /// Where the connection sockets are kept, relative to the home directory.
    public static let defaultControlDirectory = "Library/Caches/Ajoissa/cm"

    // MARK: - Looking

    /// Looks at each job once. Machines are looked at side by side, so one that does not answer holds up
    /// only its own jobs.
    ///
    /// - Parameter history: What was remembered. It is updated with what this look found, and the records of
    ///   jobs that are no longer in the config are dropped.
    /// - Returns: One report per job, in the order of the config.
    public func look(at config: Config, history: inout History, now: Date, calendar: Calendar) -> [JobReport] {
        let hosts = config.hosts.filter { host in config.jobs.contains { $0.hostID == host.id } }
        let found = Found()
        let remembered = history
        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            let machine = connect(to: hosts[index], now: now, calendar: calendar)
            for job in config.jobs where job.hostID == machine.host.id {
                found.set(job.id, look(at: job, on: machine, previous: remembered.jobs[job.id], now: now))
            }
        }
        let results = found.all
        for (id, result) in results {
            if let record = result.record {
                history.jobs[id] = record
            }
        }
        history.keepOnly(jobIDs: config.jobs.map(\.id))
        return config.jobs.compactMap { results[$0.id]?.report }
    }

    /// What was found, gathered from several machines at once.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: (report: JobReport, record: JobRecord?)] = [:]

        func set(_ id: String, _ result: (JobReport, JobRecord?)) {
            lock.withLock { results[id] = result }
        }

        var all: [String: (report: JobReport, record: JobRecord?)] {
            lock.withLock { results }
        }
    }

    /// The end of a log file on the machine a job runs on, to show a person. `nil` when there is no such file.
    public func logTail(of path: String, on host: Host) throws(HostAccessError) -> String? {
        switch host.connection {
        case .local:
            return try LogTail.read(path, on: self.host)
        case let .ssh(alias):
            let shell = remoteShell(alias)
            let facts: RemoteFacts
            do {
                facts = try RemoteHost.probe(shell)
            } catch {
                throw HostAccessError("\(host.id) cannot be reached: \(error.reason)")
            }
            return try LogTail.read(path, on: RemoteHost(name: host.id, shell: shell, facts: facts, launchctlPath: remoteLaunchctlPath))
        }
    }

    // MARK: - Machines

    /// One machine as it was found at the start of a look.
    private struct Machine {
        var host: Host
        /// For checks and logs. `nil` when the machine cannot be used.
        var access: (any HostAccess)?
        /// `nil` when the machine cannot be used, or is not a Mac.
        var collector: LaunchdCollector?
        var uptime = Uptime(awakeSince: nil, bootedAt: nil)
        /// The calendar its scheduled times are read in: its own time zone.
        var calendar: Calendar
        /// Why it could not be reached.
        var offline: String?
        /// Why it could be reached but not used.
        var problem: String?
    }

    private func connect(to host: Host, now: Date, calendar: Calendar) -> Machine {
        var machine = Machine(host: host, calendar: calendar)
        switch host.connection {
        case .local:
            machine.access = self.host
            machine.collector = collector
            machine.uptime = uptime()
        case let .ssh(alias):
            let shell = remoteShell(alias).forOneLook()
            let facts: RemoteFacts
            do {
                facts = try RemoteHost.probe(shell)
            } catch {
                switch error {
                case .unreachable, .timedOut: machine.offline = "\(host.id) cannot be reached: \(error.reason)"
                case .broken: machine.problem = "\(host.id) did not answer as expected: \(error.reason)"
                }
                return machine
            }
            let difference = abs(facts.now.timeIntervalSince(now))
            guard difference <= Self.clockTolerance else {
                machine.problem = "the clock on \(host.id) differs from this Mac's by \(LaunchdJobDefinition.compact(seconds: Int((difference / 60).rounded()) * 60))"
                return machine
            }
            let remote = RemoteHost(name: host.id, shell: shell, facts: facts, launchctlPath: remoteLaunchctlPath)
            machine.access = remote
            machine.uptime = Uptime(awakeSince: facts.awakeSince, bootedAt: facts.bootedAt)
            if let zone = facts.timeZone {
                machine.calendar.timeZone = zone
            }
            if facts.isMac {
                machine.collector = LaunchdCollector(
                    access: remote,
                    locations: LaunchdSearchLocation.standard(homeDirectory: URL(fileURLWithPath: facts.home), userID: facts.userID)
                )
            }
        }
        return machine
    }

    // MARK: - One job

    private func look(at job: Job, on machine: Machine, previous: JobRecord?, now: Date) -> (JobReport, JobRecord?) {
        var evidence = Evidence(
            hostReachable: machine.offline == nil,
            hostProblem: machine.offline ?? machine.problem,
            hostMayBeOffline: machine.host.mayBeOffline,
            awakeSince: machine.uptime.awakeSince,
            bootedAt: machine.uptime.bootedAt
        )
        var report = JobReport(job: job, state: .unknown, reason: "", schedule: job.schedule?.summary ?? "")
        report.hostMayBeOffline = machine.host.mayBeOffline
        var logPaths: [String] = []
        switch job.source {
        case let .launchd(label):
            report.source = "launchd \(label)"
            if let access = machine.access {
                guard let collector = machine.collector else {
                    return (Self.notJudged(job, "\(machine.host.id) is not a Mac, so it has no launchd jobs"), nil)
                }
                let observation = collector.observe(label: label)
                logPaths = observation.logPaths
                evidence.source = SourceEvidence(launchd: observation, logModified: Self.latestModification(of: logPaths, on: access))
                report.sourceStatus = observation.statusDescription
                if job.schedule == nil {
                    report.schedule = observation.scheduleDescription
                }
            }
        case .systemd, .cron:
            return (Self.notJudged(job, "of the schedulers, only launchd is read so far"), nil)
        case nil:
            break
        }
        let assessment = JobAssessor.assess(
            job: job,
            evidence: evidence,
            // A machine that cannot be used has its checks left alone; the assessment does not run them.
            host: machine.access ?? host,
            defaultLogPaths: logPaths,
            previous: previous,
            now: now,
            calendar: machine.calendar
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

    /// When the newest of some log files was last written. Files that are missing or cannot be looked at are
    /// skipped; `nil` when none could be.
    private static func latestModification(of paths: [String], on host: any HostAccess) -> Date? {
        paths.compactMap { path in
            (try? host.file(at: path))?.modified
        }.max()
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
