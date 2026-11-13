import AjoissaCore
import Foundation

let usage = """
    Usage:
      ajoissa validate [--config <path>]   Check the config file and report every problem in it
      ajoissa status [--config <path>]     Show what is known about each job right now
      ajoissa --version
      ajoissa --help

    The config file is ~/\(ConfigLocation.defaultRelativePath), unless --config or the
    \(ConfigLocation.environmentVariable) environment variable names another one.
    """

/// Exit codes, after sysexits.h where one fits.
enum ExitCode: Int32 {
    case success = 0
    case invalidConfig = 1
    case usage = 64
    case unreadableConfig = 66
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
    let collector = LaunchdCollector(
        runner: ProcessCommandRunner(),
        locations: LaunchdSearchLocation.standard(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            userID: getuid()
        )
    )
    for job in config.jobs {
        print(job.name == job.id ? job.id : "\(job.id) (\(job.name))")
        switch (job.source, job.hostID) {
        case let (.launchd(label), Host.localID):
            let observation = collector.observe(label: label)
            print("  launchd:  \(label)")
            print("  schedule: \(observation.scheduleDescription)")
            print("  state:    \(observation.statusDescription)")
        case (.launchd, _), (.systemd, _), (.cron, _):
            print("  state:    not read yet: only launchd jobs on this Mac are supported so far")
        case (nil, _):
            print("  state:    not read yet: this job is known only through its checks")
        }
    }
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
