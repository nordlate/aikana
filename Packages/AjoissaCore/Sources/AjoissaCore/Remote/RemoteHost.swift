import Foundation

/// What another machine said about itself when it was asked.
public struct RemoteFacts: Sendable, Equatable {
    /// The system's name as `uname -s` gives it: "Darwin" for a Mac, "Linux".
    public var system: String
    public var userID: UInt32
    /// The home folder of the user Ajoissa connects as.
    public var home: String
    /// The machine's clock at the moment it was asked.
    public var now: Date
    public var bootedAt: Date?
    /// Since when the machine has been awake without a break: the later of its last wake and its start.
    public var awakeSince: Date?
    /// The machine's time zone, when it could be told.
    public var timeZone: TimeZone?

    public init(
        system: String,
        userID: UInt32,
        home: String,
        now: Date,
        bootedAt: Date? = nil,
        awakeSince: Date? = nil,
        timeZone: TimeZone? = nil
    ) {
        self.system = system
        self.userID = userID
        self.home = home
        self.now = now
        self.bootedAt = bootedAt
        self.awakeSince = awakeSince
        self.timeZone = timeZone
    }

    public var isMac: Bool {
        system == "Darwin"
    }

    /// Reads the seven lines of ``RemoteCommands/probe``. `nil` when they are not what was asked for.
    init?(probeOutput: String) {
        let lines = probeOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 7, !lines[0].isEmpty, let userID = UInt32(lines[1]), lines[2].hasPrefix("/"),
              let seconds = TimeInterval(lines[3]) else {
            return nil
        }
        let booted = Self.kernelTime(lines[4])
        self.init(
            system: lines[0],
            userID: userID,
            home: lines[2],
            now: Date(timeIntervalSince1970: seconds),
            bootedAt: booted,
            awakeSince: [Self.kernelTime(lines[5]), booted].compactMap { $0 }.max(),
            timeZone: Self.timeZone(link: lines[6])
        )
    }

    /// A moment as the kernel prints it: "{ sec = 1763000000, usec = 0 } Thu Nov 13 …". Zero means never.
    private static func kernelTime(_ text: String) -> Date? {
        guard let start = text.range(of: "sec = ") else { return nil }
        let digits = text[start.upperBound...].prefix { $0.isNumber }
        guard let seconds = TimeInterval(digits), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The zone a link such as "/var/db/timezone/zoneinfo/Europe/Helsinki" names.
    private static func timeZone(link: String) -> TimeZone? {
        guard let marker = link.range(of: "zoneinfo/") else { return nil }
        return TimeZone(identifier: String(link[marker.upperBound...]))
    }
}

/// Another machine, reached through a shell: what checks and the launchd collector may do there.
///
/// Every script it sends comes from ``RemoteCommands``. A machine that stops answering part of the way is
/// reported as something that could not be looked at, never as a file that is not there.
public struct RemoteHost: HostAccess, LaunchdAccess {
    /// How long a script that only reads may take.
    public static let readTimeout: TimeInterval = 20

    /// The name the machine has in the config, for messages.
    public let name: String
    public let facts: RemoteFacts
    private let shell: RemoteShell
    private let launchctlPath: String

    /// - Parameter launchctlPath: Where `launchctl` is on the machine. Tests put a stand-in here.
    public init(name: String, shell: RemoteShell, facts: RemoteFacts, launchctlPath: String = LaunchdCollector.launchctl) {
        self.name = name
        self.shell = shell
        self.facts = facts
        self.launchctlPath = launchctlPath
    }

    /// Asks the machine what it is. This is the first thing sent in every look, and tells whether the
    /// machine can be reached at all.
    public static func probe(_ shell: RemoteShell) throws(RemoteShellError) -> RemoteFacts {
        let reply = try shell.run(RemoteCommands.probe, timeout: readTimeout)
        // swiftlint:disable:next optional_data_string_conversion
        guard reply.status == "ok", let facts = RemoteFacts(probeOutput: String(decoding: reply.output, as: UTF8.self)) else {
            throw .broken("it did not say what kind of machine it is")
        }
        return facts
    }

    private var stat: RemoteCommands.StatFlavour {
        facts.isMac || facts.system.hasSuffix("BSD") ? .bsd : .gnu
    }

    // MARK: - HostAccess

    public func files(matching pattern: String) throws(HostAccessError) -> [HostFile] {
        let expanded = try expand(pattern)
        let script = RemoteCommands.files(
            matching: expanded,
            folders: Self.folders(on: expanded),
            limit: LocalHost.matchLimit,
            stat: stat
        )
        let reply = try send(script, about: pattern)
        switch reply.status {
        case "ok": return try Self.files(in: reply.output, about: pattern)
        case "toomany": throw HostAccessError("\(pattern) matches more than \(LocalHost.matchLimit) files; narrow it down")
        case "unsearchable": throw HostAccessError("\(pattern) could not be searched: a folder on the way could not be read")
        default: throw unexpected(reply, about: pattern)
        }
    }

    public func file(at path: String) throws(HostAccessError) -> HostFile? {
        let expanded = try expand(path)
        let reply = try send(RemoteCommands.file(at: expanded, folders: Self.folders(on: expanded), stat: stat), about: path)
        switch reply.status {
        case "ok": return try Self.files(in: reply.output, about: path).first
        case "unsearchable": throw HostAccessError("\(path) could not be read: a folder on the way could not be read")
        default: throw unexpected(reply, about: path)
        }
    }

    public func read(_ path: String, range: Range<Int64>) throws(HostAccessError) -> Data {
        guard range.lowerBound >= 0, !range.isEmpty else { return Data() }
        let script = RemoteCommands.read(try expand(path), from: range.lowerBound, count: range.upperBound - range.lowerBound)
        let reply = try send(script, about: path)
        switch reply.status {
        case "ok": return reply.output
        case "missing": return Data()
        case "unreadable": throw HostAccessError("\(path) could not be read: permission denied")
        default: throw unexpected(reply, about: path)
        }
    }

    public func run(_ arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        guard let program = arguments.first else {
            throw .notStarted(reason: "no program was given")
        }
        guard arguments.allSatisfy(ShellQuoting.isQuotable) else {
            throw .notStarted(reason: "an argument has a line break in it")
        }
        let expandedProgram = program.hasPrefix("~/") ? facts.home + "/" + program.dropFirst(2) : program
        let reply: RemoteShell.Reply
        do {
            reply = try shell.run(RemoteCommands.run([expandedProgram] + arguments.dropFirst()), timeout: timeout)
        } catch {
            switch error {
            case .timedOut: throw .timedOut(after: timeout)
            case .unreachable, .broken: throw .notStarted(reason: "\(name) did not answer: \(error.reason)")
            }
        }
        if reply.status == "notfound" {
            throw .notStarted(reason: "there is no such program on \(name)")
        }
        guard reply.status.hasPrefix("exit "), let code = Int32(reply.status.dropFirst(5)) else {
            throw .notStarted(reason: "\(name) gave an answer that was not understood")
        }
        return CommandResult(exitCode: code, outputData: reply.output, errorOutput: reply.errorOutput)
    }

    // MARK: - LaunchdAccess

    public func launchctlPrint(_ target: String, timeout: TimeInterval) throws(CommandError) -> CommandResult {
        try run([launchctlPath, "print", target], timeout: timeout)
    }

    public func contents(ofFileAt path: String) -> FileContents {
        guard ShellQuoting.isQuotable(path),
              let reply = try? shell.run(RemoteCommands.read(path, from: 0, count: nil), timeout: Self.readTimeout) else {
            return .unreadable
        }
        switch reply.status {
        case "ok": return .data(reply.output)
        case "missing": return .missing
        default: return .unreadable
        }
    }

    public func plistNames(in directory: String) -> [String]? {
        guard ShellQuoting.isQuotable(directory),
              let reply = try? shell.run(RemoteCommands.plistNames(in: directory), timeout: Self.readTimeout) else {
            return nil
        }
        switch reply.status {
        case "ok": return Self.records(in: reply.output).sorted()
        case "missing": return []
        default: return nil
        }
    }

    /// Links are not followed on another machine. Two paths to one file then count as two files, and the one
    /// launchd names is read.
    public func resolved(_ path: String) -> String {
        path
    }

    // MARK: - Sending and reading back

    /// `~/x` is `x` in the home folder on the machine. A path that cannot be written in a script is refused.
    private func expand(_ path: String) throws(HostAccessError) -> String {
        guard ShellQuoting.isQuotable(path) else {
            throw HostAccessError("\(path) has a line break in it")
        }
        return path.hasPrefix("~/") ? facts.home + "/" + path.dropFirst(2) : path
    }

    private func send(_ script: String, about path: String) throws(HostAccessError) -> RemoteShell.Reply {
        do {
            return try shell.run(script, timeout: Self.readTimeout)
        } catch {
            throw HostAccessError("\(path) could not be looked at: \(name) did not answer: \(error.reason)")
        }
    }

    private func unexpected(_ reply: RemoteShell.Reply, about path: String) -> HostAccessError {
        HostAccessError("\(path) could not be looked at: \(name) gave an answer that was not understood")
    }

    /// The folders a path leads through before its first wildcard, outermost first. The last one must be
    /// listable when a wildcard follows it; the others only need to be entered.
    static func folders(on path: String) -> [RemoteCommands.Folder] {
        guard path.hasPrefix("/") else { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let isPattern: (String) -> Bool = { $0.contains { "*?[".contains($0) } }
        let literal = parts.prefix { !isPattern($0) }
        // The last part of a path without wildcards is the file itself, not a folder on the way.
        let count = literal.count == parts.count ? literal.count - 1 : literal.count
        return (1...max(count, 1)).prefix(count).map { length in
            RemoteCommands.Folder(
                path: "/" + parts.prefix(length).joined(separator: "/"),
                mustBeListable: length < parts.count && isPattern(parts[length])
            )
        }
    }

    /// The NUL-terminated pieces of a script's output.
    private static func records(in output: Data) -> [String] {
        // swiftlint:disable:next optional_data_string_conversion
        output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Files as the scripts print them: "modified size identity path".
    private static func files(in output: Data, about path: String) throws(HostAccessError) -> [HostFile] {
        var files: [HostFile] = []
        for record in records(in: output) {
            let fields = record.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let modified = TimeInterval(fields[0]), let size = Int64(fields[1]) else {
                throw HostAccessError("\(path) could not be looked at: the answer was not understood")
            }
            files.append(HostFile(
                path: String(fields[3]),
                modified: Date(timeIntervalSince1970: modified),
                size: size,
                identity: UInt64(fields[2])
            ))
        }
        return files
    }
}
