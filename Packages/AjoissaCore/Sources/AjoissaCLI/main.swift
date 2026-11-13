import AjoissaCore
import Foundation

let usage = """
    Usage:
      ajoissa validate [--config <path>]   Check the config file and report every problem in it
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

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usageError(_ message: String) -> ExitCode {
    printError("ajoissa: \(message)")
    printError(usage)
    return .usage
}

func validate(_ arguments: [String]) -> ExitCode {
    var explicitPath: String?
    switch arguments.count {
    case 0:
        break
    case 2 where arguments[0] == "--config":
        explicitPath = arguments[1]
    default:
        return usageError("validate takes only --config <path>")
    }
    let url = ConfigLocation.resolve(
        explicitPath: explicitPath,
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
    do {
        let config = try ConfigLoader.load(contentsOf: url)
        print("\(url.path): OK, \(config.jobs.count) jobs on \(config.hosts.count) hosts")
        return .success
    } catch {
        printError("\(url.path): not usable")
        error.lines.forEach { printError("  \($0)") }
        if case .unreadable = error {
            return .unreadableConfig
        }
        return .invalidConfig
    }
}

func run(_ arguments: [String]) -> ExitCode {
    switch arguments.first {
    case "validate":
        return validate(Array(arguments.dropFirst()))
    case "--version", "-v":
        print("ajoissa \(AjoissaCore.version)")
        return .success
    case nil, "--help", "-h":
        print(usage)
        return .success
    case let unknown?:
        return usageError("unknown argument '\(unknown)'")
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())).rawValue)
