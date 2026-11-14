import Foundation

/// One thing that is wrong in a config file, with where it is.
public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    /// Where the problem is, for example `jobs[1] (nightly-report).schedule.daily`. Empty for the file as a whole.
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        path.isEmpty ? message : "\(path): \(message)"
    }
}

/// Why a config could not be loaded.
public enum ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The file could not be read at all.
    case unreadable(path: String, reason: String)
    /// The file is not well-formed JSON5.
    case syntax(message: String)
    /// The file parses but breaks one or more rules. Never empty.
    case invalid([ConfigIssue])

    /// One line per problem, written for a person.
    public var lines: [String] {
        switch self {
        case let .unreadable(path, reason):
            ["Cannot read \(path): \(reason)"]
        case let .syntax(message):
            ["Not valid JSON5: \(message)"]
        case let .invalid(issues):
            issues.map(\.description)
        }
    }

    public var description: String {
        lines.joined(separator: "\n")
    }
}
