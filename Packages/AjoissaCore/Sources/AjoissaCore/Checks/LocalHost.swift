import Foundation

/// This Mac, as a place to run checks.
public struct LocalHost: HostAccess {
    /// A pattern that matches more files than this is cut off. No check needs to look at more.
    static let matchLimit = 10000

    private let homeDirectory: URL
    private let runner: any CommandRunner

    public init(homeDirectory: URL, runner: any CommandRunner) {
        self.homeDirectory = homeDirectory
        self.runner = runner
    }

    public func files(matching pattern: String) throws(HostAccessError) -> [HostFile] {
        let expanded = expand(pattern)
        var matches = glob_t()
        defer { globfree(&matches) }
        // GLOB_ERR makes a folder that cannot be read an error. Without it such a folder would simply match
        // nothing, and "could not look" would be taken for "is not there".
        switch glob(expanded, GLOB_ERR | GLOB_NOSORT, nil, &matches) {
        case 0:
            break
        case GLOB_NOMATCH:
            // A plain path that matched nothing may be missing or may be out of reach; this tells which.
            return try file(atExpanded: expanded, shownAs: pattern).map { [$0] } ?? []
        default:
            throw HostAccessError("\(pattern) could not be searched: a folder on the way could not be read")
        }
        var files: [HostFile] = []
        for index in 0..<min(Int(matches.gl_pathc), Self.matchLimit) {
            guard let pointer = matches.gl_pathv[index], let path = String(validatingCString: pointer) else { continue }
            if let file = try file(atExpanded: path, shownAs: path) {
                files.append(file)
            }
        }
        return files
    }

    public func file(at path: String) throws(HostAccessError) -> HostFile? {
        try file(atExpanded: expand(path), shownAs: path)
    }

    /// - Parameter shown: The path as the user wrote it, for the message if it cannot be read.
    private func file(atExpanded expanded: String, shownAs shown: String) throws(HostAccessError) -> HostFile? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: expanded)
        } catch {
            if Self.isNoSuchFile(error) {
                return nil
            }
            throw HostAccessError("\(shown) could not be read: \(error.localizedDescription)")
        }
        // Folders and other things that are not files have no contents a check could mean.
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return HostFile(path: expanded, modified: modified, size: size.int64Value)
    }

    public func read(_ path: String, from offset: Int64, limit: Int) throws(HostAccessError) -> Data {
        let expanded = expand(path)
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expanded))
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let start = max(UInt64(max(offset, 0)), end > UInt64(limit) ? end - UInt64(limit) : 0)
            guard start < end else { return Data() }
            try handle.seek(toOffset: start)
            return try handle.readToEnd() ?? Data()
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
