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
    let (url, _) = try loadConfig("status", arguments)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let session = WatchSession(
        configURL: url,
        historyFile: HistoryFile(environment: ProcessInfo.processInfo.environment, homeDirectory: home),
        watch: LocalWatch(homeDirectory: home, userID: getuid())
    )
    switch session.round(now: Date(), calendar: .current) {
    case let .configProblem(error):
        // The file was usable a moment ago; it was changed in between.
        printError("\(url.path): not usable")
        error.lines.forEach { printError("  \($0)") }
        throw Stop(code: .invalidConfig)
    case let .historyProblem(error):
        throw historyProblem(error)
    case let .looked(_, reports, saveProblem):
        reports.forEach(show)
        if let saveProblem {
            throw historyProblem(saveProblem)
        }
    }
}

func show(_ report: JobReport) {
    let job = report.job
    print(job.name == job.id ? job.id : "\(job.id) (\(job.name))")
    if let source = report.source, let status = report.sourceStatus {
        let (scheduler, name) = source.split(separator: " ", maxSplits: 1).map(String.init).pair
        print("  \(scheduler):".padding(toLength: 12, withPad: " ", startingAt: 0) + name)
        print("  schedule: \(report.schedule)")
        print("  state:    \(status)")
    }
    for check in report.checks {
        print("  check:    \(check.label): \(check.outcome.summary)")
    }
    print("  verdict:  \(report.isJudged ? "\(report.state.rawValue): " : "")\(report.reason)")
}

extension Array where Element == String {
    /// The first two elements; empty text for one that is not there.
    var pair: (String, String) {
        (first ?? "", count > 1 ? self[1] : "")
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
