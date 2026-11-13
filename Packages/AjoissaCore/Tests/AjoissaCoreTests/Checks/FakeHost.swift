import AjoissaCore
import Foundation

/// A machine made of a few files and canned answers, standing in for the one a job runs on.
final class FakeHost: HostAccess, @unchecked Sendable {
    struct File {
        var modified: Date
        var contents: Data
        /// The size to report. A backup of 500 MB does not have to exist to be checked.
        var size: Int64
        var identity: UInt64
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var unreadable: Set<String> = []
    private var commandAnswer: Result<CommandResult, CommandError> = .success(CommandResult(exitCode: 0))
    private var recordedCommands: [[String]] = []
    private var recordedReads: [String] = []
    private var nextIdentity: UInt64 = 100

    var commands: [[String]] {
        lock.withLock { recordedCommands }
    }

    /// Every read of file contents, in order, as "path from..<to".
    var reads: [String] {
        lock.withLock { recordedReads }
    }

    /// Writes a file. Writing to a path again keeps it the same file, as appending or rewriting in place
    /// does, unless `replaced` says a new file took its name, as rotating a log does.
    func put(_ path: String, modified: String, contents: String = "", size: Int64? = nil, replaced: Bool = false) {
        put(path, modified: modified, data: Data(contents.utf8), size: size, replaced: replaced)
    }

    func put(_ path: String, modified: String, data: Data, size: Int64? = nil, replaced: Bool = false) {
        lock.withLock {
            nextIdentity += 1
            let identity = replaced ? nextIdentity : files[path]?.identity ?? nextIdentity
            files[path] = File(modified: TestClock.date(modified), contents: data, size: size ?? Int64(data.count), identity: identity)
        }
    }

    func remove(_ path: String) {
        lock.withLock { files[path] = nil }
    }

    /// Makes every look at this path or pattern fail, as a folder without permission would.
    func makeUnreadable(_ path: String) {
        lock.withLock { _ = unreadable.insert(path) }
    }

    func answerCommands(with result: Result<CommandResult, CommandError>) {
        lock.withLock { commandAnswer = result }
    }

    func files(matching pattern: String) throws(HostAccessError) -> [HostFile] {
        try refuseIfUnreadable(pattern)
        return lock.withLock {
            files.filter { fnmatch(pattern, $0.key, FNM_PATHNAME) == 0 }
                .map { HostFile(path: $0.key, modified: $0.value.modified, size: $0.value.size, identity: $0.value.identity) }
                .sorted { $0.path < $1.path }
        }
    }

    func file(at path: String) throws(HostAccessError) -> HostFile? {
        try refuseIfUnreadable(path)
        return lock.withLock {
            files[path].map { HostFile(path: path, modified: $0.modified, size: $0.size, identity: $0.identity) }
        }
    }

    func read(_ path: String, range: Range<Int64>) throws(HostAccessError) -> Data {
        try refuseIfUnreadable(path)
        return lock.withLock {
            recordedReads.append("\(path) \(range.lowerBound)..<\(range.upperBound)")
            guard let contents = files[path]?.contents else { return Data() }
            let start = min(max(Int(range.lowerBound), 0), contents.count)
            let end = min(max(Int(range.upperBound), start), contents.count)
            return contents.subdata(in: start..<end)
        }
    }

    func run(_ arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        let answer = lock.withLock {
            recordedCommands.append(arguments)
            return commandAnswer
        }
        return try answer.get()
    }

    private func refuseIfUnreadable(_ path: String) throws(HostAccessError) {
        if lock.withLock({ unreadable.contains(path) }) {
            throw HostAccessError("\(path) could not be read: permission denied")
        }
    }
}
