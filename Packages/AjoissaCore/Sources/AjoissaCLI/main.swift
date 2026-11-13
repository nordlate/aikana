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
    let collector = LaunchdCollector(
        runner: ProcessCommandRunner(),
        locations: LaunchdSearchLocation.standard(homeDirectory: home, userID: getuid())
    )
    let awakeSince = SystemUptime.awakeSince()

    for job in config.jobs {
        print(job.name == job.id ? job.id : "\(job.id) (\(job.name))")
        guard case let .launchd(label) = job.source, job.hostID == Host.localID else {
            print("  verdict:  not judged yet: only launchd jobs on this Mac are supported so far")
            continue
        }
        let observation = collector.observe(label: label)
        let evidence = Evidence(
            source: SourceEvidence(launchd: observation, logModified: FileTimes.latestModification(of: observation.logPaths)),
            awakeSince: awakeSince
        )
        let evaluation = JobEvaluator.evaluate(
            job: job,
            evidence: evidence,
            previous: history.jobs[job.id],
            now: Date(),
            calendar: .current
        )
        history.jobs[job.id] = evaluation.record
        print("  launchd:  \(label)")
        print("  schedule: \(observation.scheduleDescription)")
        print("  state:    \(observation.statusDescription)")
        print("  verdict:  \(evaluation.state.rawValue): \(evaluation.reason)")
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
