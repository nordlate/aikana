import AjoissaCore
import Foundation

let usage = """
    Usage: ajoissa [--version] [--help]

    Ajoissa checks that scheduled jobs ran. Commands such as `validate` and `status` are not implemented yet.
    """

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--version", "-v":
    print("ajoissa \(AjoissaCore.version)")
case nil, "--help", "-h":
    print(usage)
case let unknown?:
    printError("ajoissa: unknown argument '\(unknown)'")
    printError(usage)
    exit(64)
}
