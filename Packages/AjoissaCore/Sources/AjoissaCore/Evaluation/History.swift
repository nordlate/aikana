import Foundation

/// What Ajoissa remembers between evaluations: one record per job, by job id.
public struct History: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var jobs: [String: JobRecord]

    public init(jobs: [String: JobRecord] = [:]) {
        version = Self.currentVersion
        self.jobs = jobs
    }

    /// Drops the records of jobs that are no longer in the config.
    public mutating func keepOnly(jobIDs: some Sequence<String>) {
        let wanted = Set(jobIDs)
        jobs = jobs.filter { wanted.contains($0.key) }
    }
}

public enum HistoryError: Error, Sendable, Equatable {
    /// The file exists but cannot be read or is not a history Ajoissa understands.
    case unreadable(path: String, reason: String)
    case unwritable(path: String, reason: String)
}

/// The history as a file on disk.
public struct HistoryFile: Sendable {
    /// Where the history lives, relative to the home directory.
    public static let defaultRelativePath = "Library/Application Support/Ajoissa/history.json"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The environment variable that names a history file other than the default one.
    public static let environmentVariable = "AJOISSA_HISTORY"

    /// The history file to use: the one `AJOISSA_HISTORY` names, or the default under the home directory.
    public init(environment: [String: String], homeDirectory: URL) {
        if let path = environment[Self.environmentVariable], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = homeDirectory.appending(path: Self.defaultRelativePath, directoryHint: .notDirectory)
        }
    }

    /// The stored history. A file that does not exist yet is an empty history, not an error.
    ///
    /// A file that cannot be understood is an error, and is never silently replaced: starting over would forget
    /// which runs were seen and make every job look unwatched.
    public func load() throws(HistoryError) -> History {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileReadNoSuchFileError {
                return History()
            }
            throw .unreadable(path: url.path, reason: error.localizedDescription)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let history = try decoder.decode(History.self, from: data)
            guard history.version == History.currentVersion else {
                throw HistoryError.unreadable(path: url.path, reason: "it is version \(history.version), and this Ajoissa reads version \(History.currentVersion)")
            }
            return history
        } catch let error as HistoryError {
            throw error
        } catch {
            throw .unreadable(path: url.path, reason: "it is not a valid history file")
        }
    }

    /// Writes the history, replacing the file in one step so a crash cannot leave half of it.
    public func save(_ history: History) throws(HistoryError) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Times are kept to the second, readable by a person. The evaluation never needs finer than that.
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(path: url.path, reason: error.localizedDescription)
        }
    }
}
