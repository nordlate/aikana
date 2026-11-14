import Foundation

/// This Mac, as a place to run checks.
public struct LocalHost: HostAccess {
    /// A pattern that matches more files than this is refused. Judging "the newest" from a part of them
    /// would be a guess.
    static let matchLimit = 10000

    private let homeDirectory: URL
    private let runner: any CommandRunner

    public init(homeDirectory: URL, runner: any CommandRunner) {
        self.homeDirectory = homeDirectory
        self.runner = runner
    }

    public func files(matching pattern: String) throws(HostAccessError) -> [HostFile] {
        let expanded = expand(pattern)
        let paths: [String]
        switch Self.expandPattern(expanded) {
        case let .matches(found):
            paths = found
        case .none:
            // Nothing matched. That is only an answer if every folder on the way could be searched; a folder
            // without permission matches nothing either, and must not be taken for "is not there".
            if Self.hasUnsearchableFolder(on: expanded) {
                throw HostAccessError("\(pattern) could not be searched: a folder on the way could not be read")
            }
            // A plain path may also be out of reach in other ways; the look at the file itself tells.
            return try file(atExpanded: expanded, shownAs: pattern).map { [$0] } ?? []
        case .failed:
            throw HostAccessError("\(pattern) could not be searched: a folder on the way could not be read")
        }
        guard paths.count <= Self.matchLimit else {
            throw HostAccessError("\(pattern) matches more than \(Self.matchLimit) files; narrow it down")
        }
        var files: [HostFile] = []
        for path in paths {
            // A file can vanish between being listed and being looked at; then it is simply not there.
            if let file = try file(atExpanded: path, shownAs: path) {
                files.append(file)
            }
        }
        return files
    }

    public func file(at path: String) throws(HostAccessError) -> HostFile? {
        try file(atExpanded: expand(path), shownAs: path)
    }

    public func read(_ path: String, range: Range<Int64>) throws(HostAccessError) -> Data {
        let expanded = expand(path)
        guard range.lowerBound >= 0, !range.isEmpty else { return Data() }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expanded))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        } catch {
            if Self.isNoSuchFile(error) {
                return Data()
            }
            throw HostAccessError("\(path) could not be read: \(error.localizedDescription)")
        }
    }

    public func run(_ arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult {
        guard let program = arguments.first else {
            throw .notStarted(reason: "no program was given")
        }
        return try runner.run(expand(program), arguments: Array(arguments.dropFirst()), timeout: timeout)
    }

    // MARK: - One file

    /// - Parameter shown: The path as the user wrote it, for the message if it cannot be read.
    private func file(atExpanded expanded: String, shownAs shown: String) throws(HostAccessError) -> HostFile? {
        // `stat` follows links, so a log that is a link is seen as the file it points at. Looking at the link
        // itself would report a few bytes that never change.
        var info = stat()
        guard stat(expanded, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            throw HostAccessError("\(shown) could not be read: \(String(cString: strerror(errno)))")
        }
        // Folders and other things that are not files have no contents a check could mean.
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return HostFile(path: expanded, modified: modified, size: Int64(info.st_size), identity: UInt64(info.st_ino))
    }

    // MARK: - Patterns

    private enum Expansion {
        case matches([String])
        case none
        case failed
    }

    private static func expandPattern(_ pattern: String) -> Expansion {
        var matches = glob_t()
        defer { globfree(&matches) }
        // GLOB_ERR makes a folder that cannot be listed an error instead of an empty match.
        switch glob(pattern, GLOB_ERR, nil, &matches) {
        case 0:
            let paths = (0..<Int(matches.gl_pathc)).compactMap { index in
                matches.gl_pathv[index].flatMap { String(validatingCString: $0) }
            }
            return .matches(paths)
        case GLOB_NOMATCH:
            return .none
        default:
            return .failed
        }
    }

    /// Whether some folder that the pattern leads through exists but cannot be entered or listed. `glob` skips
    /// such a folder silently when the part after it is a plain name, so this is checked separately, and only
    /// when nothing matched.
    private static func hasUnsearchableFolder(on pattern: String) -> Bool {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return false }
        for count in 1..<parts.count {
            let folderPattern = "/" + parts.prefix(count).joined(separator: "/")
            guard case let .matches(folders) = expandPattern(folderPattern) else { continue }
            let nextHasWildcard = parts[count].contains(where: { "*?[".contains($0) })
            for folder in folders where isDirectory(folder) {
                // Entering a folder needs search permission; matching a wildcard inside it also needs to list it.
                if access(folder, X_OK) != 0 || (nextHasWildcard && access(folder, R_OK) != 0) {
                    return true
                }
            }
        }
        return false
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `~/x` is `x` in the home directory. Nothing else about a path is changed.
    private func expand(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return homeDirectory.appending(path: String(path.dropFirst(2)), directoryHint: .notDirectory).path
    }

    private static func isNoSuchFile(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }
}
