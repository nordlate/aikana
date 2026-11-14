import Foundation

/// What reading a file came to.
public enum FileContents: Sendable, Equatable {
    case data(Data)
    case missing
    /// The file may exist, but reading it failed for another reason than its absence.
    case unreadable
}

/// What the launchd collector needs from the Mac whose jobs it reads. All of it only reads.
public protocol LaunchdAccess: Sendable {
    /// Runs `launchctl print <target>`.
    func launchctlPrint(_ target: String, timeout: TimeInterval) throws(CommandError) -> CommandResult

    func contents(ofFileAt path: String) -> FileContents

    /// The names of the plist files in a folder, sorted. Empty when the folder does not exist, `nil` when it
    /// exists but cannot be read.
    func plistNames(in directory: String) -> [String]?

    /// The path with links followed, as far as that can be told, for comparing two paths to one file.
    func resolved(_ path: String) -> String
}

/// launchd on this Mac.
public struct LocalLaunchdAccess: LaunchdAccess {
    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func launchctlPrint(_ target: String, timeout: TimeInterval) throws(CommandError) -> CommandResult {
        try runner.run(LaunchdCollector.launchctl, arguments: ["print", target], timeout: timeout)
    }

    public func contents(ofFileAt path: String) -> FileContents {
        do {
            return .data(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            return Self.isNoSuchFile(error) ? .missing : .unreadable
        }
    }

    public func plistNames(in directory: String) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { $0.hasSuffix(".plist") }
                .sorted()
        } catch {
            return Self.isNoSuchFile(error) ? [] : nil
        }
    }

    public func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func isNoSuchFile(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }
}
