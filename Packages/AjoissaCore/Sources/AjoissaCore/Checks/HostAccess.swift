import Foundation

/// A file on the machine a job runs on, as much of it as a check needs.
public struct HostFile: Sendable, Equatable {
    public let path: String
    public let modified: Date
    public let size: Int64

    public init(path: String, modified: Date, size: Int64) {
        self.path = path
        self.modified = modified
        self.size = size
    }
}

/// Something on the host could not be looked at. This is not the same as it not being there.
public struct HostAccessError: Error, Sendable, Equatable {
    /// What could not be done, written for a person: "/var/log/x could not be read: permission denied".
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// What a check may do on the machine a job runs on. Everything except `run` only reads.
///
/// Checks are written against this, so they work the same on this Mac and, later, on another machine over SSH.
public protocol HostAccess: Sendable {
    /// The regular files a path matches. The path may contain `*`, `?` and `[...]`, and may start with `~/`
    /// for the home directory on the host. No match is an empty list, not an error.
    func files(matching pattern: String) throws(HostAccessError) -> [HostFile]

    /// The file at exactly this path, or `nil` if there is none.
    func file(at path: String) throws(HostAccessError) -> HostFile?

    /// The contents of a file from `offset` to its end. If that is more than `limit` bytes, only the last
    /// `limit` bytes. Empty when the file is shorter than `offset` or does not exist.
    func read(_ path: String, from offset: Int64, limit: Int) throws(HostAccessError) -> Data

    /// Runs a program on the host: the first argument is the program, the rest are passed as they are,
    /// without a shell.
    func run(_ arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult
}
