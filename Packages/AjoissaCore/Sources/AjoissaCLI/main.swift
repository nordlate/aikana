import AjoissaCore
import Foundation

let usage = """
    Usage:
      ajoissa validate [--config <path>]   Check the config file and report every problem in it
      ajoissa status [--config <path>]     Judge each job now, show the verdict and remember it
      ajoissa --version
      ajoissa --help

    The config file is ~/\(ConfigLocation.defaultRelativePath), unless --config or the
    \(ConfigLocation.environmentVariable) environment variable names another one.
    What status has seen is kept in ~/\(HistoryFile.defaultRelativePath),
    unless \(HistoryFile.environmentVariable) names another file.
    """

/// Exit codes, after sysexits.h where one fits.
enum ExitCode: Int32 {
    case success = 0
    case invalidConfig = 1
    case usage = 64
    case unreadableConfig = 66
    case unusableHistory = 74
}

/// Why a command stopped before doing its work.
struct Stop: Error {
    let code: ExitCode
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usageError(_ message: String) -> Stop {
    printError("ajoissa: \(message)")
    printError(usage)
    return Stop(code: .usage)
}

/// Loads the config a command was asked to use, reporting what is wrong with it if it cannot be used.
func loadConfig(_ command: String, _ arguments: [String]) throws(Stop) -> (url: URL, config: Config) {
    var explicitPath: String?
    switch arguments.count {
    case 0:
        break
    case 2 where arguments[0] == "--config":
        explicitPath = arguments[1]
    default:
        throw usageError("\(command) takes only --config <path>")
    }
    let url = ConfigLocation.resolve(
        explicitPath: explicitPath,
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
    do {
        return (url, try ConfigLoader.load(contentsOf: url))
    } catch {
        printError("\(url.path): not usable")
        error.lines.forEach { printError("  \($0)") }
        if case .unreadable = error {
            throw Stop(code: .unreadableConfig)
        }
        throw Stop(code: .invalidConfig)
    }
}

func validate(_ arguments: [String]) throws(Stop) {
    let (url, config) = try loadConfig("validate", arguments)
    print("\(url.path): OK, \(config.jobs.count) jobs on \(config.hosts.count) hosts")
}

/// What `status` needs to look at the jobs on this Mac.
struct LocalLook {
    let collector: LaunchdCollector
    let host: LocalHost
    let awakeSince = SystemUptime.awakeSince()
    let bootedAt = SystemUptime.bootedAt()

    init(home: URL) {
        let runner = ProcessCommandRunner()
        collector = LaunchdCollector(runner: runner, locations: LaunchdSearchLocation.standard(homeDirectory: home, userID: getuid()))
        host = LocalHost(homeDirectory: home, runner: runner)
    }

    /// Looks at one job, prints what was found and returns the record to keep. `nil` for a job that cannot be
    /// looked at yet.
    func assess(_ job: Job, previous: JobRecord?) -> JobRecord? {
        guard job.hostID == Host.localID else {
            print("  verdict:  not judged yet: only jobs on this Mac are supported so far")
            return nil
        }
        var evidence = Evidence(awakeSince: awakeSince, bootedAt: bootedAt)
        var logPaths: [String] = []
        switch job.source {
        case let .launchd(label):
            let observation = collector.observe(label: label)
            logPaths = observation.logPaths
            evidence.source = SourceEvidence(launchd: observation, logModified: FileTimes.latestModification(of: logPaths))
            print("  launchd:  \(label)")
            print("  schedule: \(observation.scheduleDescription)")
            print("  state:    \(observation.statusDescription)")
        case .systemd, .cron:
            print("  verdict:  not judged yet: of the schedulers, only launchd is read so far")
            return nil
        case nil:
            break
        }
        let assessment = JobAssessor.assess(
            job: job,
            evidence: evidence,
            host: host,
            defaultLogPaths: logPaths,
            previous: previous,
            now: Date(),
            calendar: .current
        )
        for (check, outcome) in zip(job.checks, assessment.outcomes) {
            print("  check:    \(check.label): \(outcome.summary)")
        }
        print("  verdict:  \(assessment.evaluation.state.rawValue): \(assessment.evaluation.reason)")
        return assessment.evaluation.record
    }
}

func status(_ arguments: [String]) throws(Stop) {
    let (_, config) = try loadConfig("status", arguments)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let historyFile = HistoryFile(environment: ProcessInfo.processInfo.environment, homeDirectory: home)
    var history: History
    do {
        history = try historyFile.load()
    } catch {
        throw historyProblem(error)
    }
    let look = LocalLook(home: home)
    for job in config.jobs {
        print(job.name == job.id ? job.id : "\(job.id) (\(job.name))")
        if let record = look.assess(job, previous: history.jobs[job.id]) {
            history.jobs[job.id] = record
        }
    }
    history.keepOnly(jobIDs: config.jobs.map(\.id))
    do {
        try historyFile.save(history)
    } catch {
        throw historyProblem(error)
    }
}

func historyProblem(_ error: HistoryError) -> Stop {
    switch error {
    case let .unreadable(path, reason):
        printError("\(path): cannot be used as the history: \(reason)")
        printError("  Move it aside to start a new history. Runs seen so far will then be forgotten.")
    case let .unwritable(path, reason):
        printError("\(path): the history could not be saved: \(reason)")
    }
    return Stop(code: .unusableHistory)
}

func run(_ arguments: [String]) throws(Stop) {
    let rest = Array(arguments.dropFirst())
    switch arguments.first {
    case "validate":
        try validate(rest)
    case "status":
        try status(rest)
    case "--version", "-v":
        print("ajoissa \(AjoissaCore.version)")
    case nil, "--help", "-h":
        print(usage)
    case let unknown?:
        throw usageError("unknown argument '\(unknown)'")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    exit(error.code.rawValue)
}
