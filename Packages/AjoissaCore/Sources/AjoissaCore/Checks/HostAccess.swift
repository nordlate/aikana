import Foundation

/// A file on the machine a job runs on, as much of it as a check needs.
public struct HostFile: Sendable, Equatable {
    public let path: String
    public let modified: Date
    public let size: Int64
    /// A number that stays the same as long as this is the same file, and differs once the file has been
    /// replaced by another of the same name. `nil` when the host cannot tell.
    public let identity: UInt64?

    public init(path: String, modified: Date, size: Int64, identity: UInt64? = nil) {
        self.path = path
        self.modified = modified
        self.size = size
        self.identity = identity
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

    /// The file at exactly this path, or `nil` if there is none. A link is followed to the file it points at.
    func file(at path: String) throws(HostAccessError) -> HostFile?

    /// The bytes of a file in `range`, as far as the file reaches. Empty when the file is shorter than the
    /// start of the range or does not exist.
    func read(_ path: String, range: Range<Int64>) throws(HostAccessError) -> Data

    /// Runs a program on the host: the first argument is the program, the rest are passed as they are,
    /// without a shell.
    func run(_ arguments: [String], timeout: TimeInterval) throws(CommandError) -> CommandResult
}
