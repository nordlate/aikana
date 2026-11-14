import Foundation

/// The part of launchd a job lives in. It decides how the job is addressed.
public enum LaunchdDomain: Sendable, Equatable {
    /// Agents of the logged-in user with this user id.
    case user(id: UInt32)
    /// Daemons.
    case system

    /// How `launchctl` names a job in this domain.
    func target(label: String) -> String {
        switch self {
        case let .user(id): "gui/\(id)/\(label)"
        case .system: "system/\(label)"
        }
    }
}

/// A folder that holds launchd job definitions, and the domain its jobs are loaded into.
public struct LaunchdSearchLocation: Sendable, Equatable {
    public let directory: URL
    public let domain: LaunchdDomain

    public init(directory: URL, domain: LaunchdDomain) {
        self.directory = directory
        self.domain = domain
    }

    /// The three folders a user's own jobs live in: their agents, the agents for all users, and the daemons.
    public static func standard(homeDirectory: URL, userID: UInt32) -> [Self] {
        [
            Self(directory: homeDirectory.appending(path: "Library/LaunchAgents"), domain: .user(id: userID)),
            Self(directory: URL(fileURLWithPath: "/Library/LaunchAgents"), domain: .user(id: userID)),
            Self(directory: URL(fileURLWithPath: "/Library/LaunchDaemons"), domain: .system)
        ]
    }
}

/// What Aikana could find out about one launchd job at one moment.
public struct LaunchdObservation: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// launchd knows the job.
        case loaded(LaunchdServiceState)
        /// The job has a plist, but launchd has not loaded it, so it will never run.
        case notLoaded
        /// There is no plist for the label and launchd does not know it either.
        case plistMissing
        /// The state could not be read. This is not the same as a problem with the job.
        case unknown(reason: String)
    }

    public let label: String
    public let status: Status
    public let domain: LaunchdDomain?
    public let plistPath: String?
    public let definition: LaunchdJobDefinition?
    /// Why the plist could not be used, when it was found but not understood.
    public let definitionProblem: String?

    public init(
        label: String,
        status: Status,
        domain: LaunchdDomain? = nil,
        plistPath: String? = nil,
        definition: LaunchdJobDefinition? = nil,
        definitionProblem: String? = nil
    ) {
        self.label = label
        self.status = status
        self.domain = domain
        self.plistPath = plistPath
        self.definition = definition
        self.definitionProblem = definitionProblem
    }
}

/// Reads the state of launchd jobs on one Mac. It only reads: it never loads, starts, stops or edits a job.
///
/// It runs exactly one command, `/bin/launchctl print <domain>/<label>`, and reads plist files, both through
/// a ``LaunchdAccess``: this Mac's, or another Mac's over SSH.
public struct LaunchdCollector: Sendable {
    public static let launchctl = "/bin/launchctl"
    static let timeout: TimeInterval = 10
    /// `launchctl print` exits with this when the domain has no such job.
    static let serviceNotFoundExitCode: Int32 = 113

    private let access: any LaunchdAccess
    private let locations: [LaunchdSearchLocation]

    /// A collector for this Mac.
    public init(runner: any CommandRunner, locations: [LaunchdSearchLocation]) {
        self.init(access: LocalLaunchdAccess(runner: runner), locations: locations)
    }

    public init(access: any LaunchdAccess, locations: [LaunchdSearchLocation]) {
        self.access = access
        self.locations = locations
    }

    public func observe(label: String) -> LaunchdObservation {
        // The label becomes part of an argument to launchctl. Refuse anything that is not one plain word.
        guard PlainName.isValid(label) else {
            return LaunchdObservation(label: label, status: .unknown(reason: "the label is not a plain name"))
        }
        let search = locate(label: label)
        let found = search.found
        // The folder a plist is in says where the job should be loaded, so that domain is asked first. The others
        // are asked too: a job can be loaded from another file, and without a plist it can be loaded anywhere.
        let expectedDomain = found?.location?.domain
        for domain in [expectedDomain].compactMap({ $0 }) + uniqueDomains.filter({ $0 != expectedDomain }) {
            switch query(label: label, in: domain) {
            case .notFound:
                continue
            case let .failed(reason):
                return observation(label, .unknown(reason: reason), domain: domain, found: found)
            case let .state(state):
                return observation(label, .loaded(state), domain: domain, found: loadedDefinition(state, found: found))
            }
        }
        if found == nil, let unreadable = search.unreadable.first {
            let reason = "\(unreadable) could not be read, so it is not known whether the job has a plist"
            return observation(label, .unknown(reason: reason), domain: nil, found: nil)
        }
        return observation(label, found == nil ? .plistMissing : .notLoaded, domain: expectedDomain, found: found)
    }

    // MARK: - launchctl

    private enum QueryResult {
        case state(LaunchdServiceState)
        case notFound
        case failed(reason: String)
    }

    private func query(label: String, in domain: LaunchdDomain) -> QueryResult {
        let result: CommandResult
        do {
            result = try access.launchctlPrint(domain.target(label: label), timeout: Self.timeout)
        } catch {
            switch error {
            case let .notStarted(reason): return .failed(reason: "launchctl could not be started: \(reason)")
            case .timedOut: return .failed(reason: "launchctl did not answer in time")
            }
        }
        if result.exitCode == Self.serviceNotFoundExitCode || result.errorOutput.contains("Could not find service") {
            return .notFound
        }
        guard result.exitCode == 0 else {
            return .failed(reason: "launchctl print failed with exit code \(result.exitCode)")
        }
        guard let state = LaunchctlPrintParser.parse(result.output) else {
            return .failed(reason: "the output of launchctl print was not understood")
        }
        return .state(state)
    }

    private var uniqueDomains: [LaunchdDomain] {
        locations.map(\.domain).reduce(into: []) { domains, domain in
            if !domains.contains(domain) {
                domains.append(domain)
            }
        }
    }

    // MARK: - Plist files

    private struct Found {
        let location: LaunchdSearchLocation?
        let path: String
        let definition: LaunchdJobDefinition?
        let problem: String?
    }

    private struct Search {
        var found: Found?
        /// Files and folders that exist, or may exist, but could not be read.
        var unreadable: [String] = []
    }

    private func observation(_ label: String, _ status: LaunchdObservation.Status, domain: LaunchdDomain?, found: Found?) -> LaunchdObservation {
        LaunchdObservation(
            label: label,
            status: status,
            domain: domain,
            plistPath: found?.path,
            definition: found?.definition,
            definitionProblem: found?.problem
        )
    }

    /// Finds the plist that defines `label`. A plist is usually named after its label, but does not have to be,
    /// so the folders are searched by content when no file has the expected name.
    private func locate(label: String) -> Search {
        var unreadable: [String] = []
        let found = findByName(label, unreadable: &unreadable) ?? findByContent(label, unreadable: &unreadable)
        return Search(found: found, unreadable: unreadable)
    }

    private func findByName(_ label: String, unreadable: inout [String]) -> Found? {
        for location in locations {
            let expected = location.directory.appending(path: "\(label).plist")
            switch access.contents(ofFileAt: expected.path) {
            case .missing:
                continue
            case .unreadable:
                unreadable.append(expected.path)
            case let .data(data):
                switch Self.read(data) {
                case let .success(definition) where definition.label == label:
                    return Found(location: location, path: expected.path, definition: definition, problem: nil)
                case .success:
                    // The file is named after this label but defines another job.
                    continue
                case let .failure(error):
                    return Found(location: location, path: expected.path, definition: nil, problem: error.reason)
                }
            }
        }
        return nil
    }

    private func findByContent(_ label: String, unreadable: inout [String]) -> Found? {
        for location in locations {
            guard let names = access.plistNames(in: location.directory.path) else {
                unreadable.append(location.directory.path)
                continue
            }
            for name in names {
                // The path is built from the folder as it was given; a listing would resolve symbolic links in it.
                let file = location.directory.appending(path: name)
                guard case let .data(data) = access.contents(ofFileAt: file.path), case let .success(definition) = Self.read(data),
                      definition.label == label else { continue }
                return Found(location: location, path: file.path, definition: definition, problem: nil)
            }
        }
        return nil
    }

    /// The definition that goes with a loaded job. launchd says which file it loaded the job from; when that is
    /// not the file found in the search folders, the file launchd names is the one that counts.
    private func loadedDefinition(_ state: LaunchdServiceState, found: Found?) -> Found? {
        // launchd also reports things that are not paths here, such as "(submitted by smd.545)".
        guard let reported = state.plistPath, reported.hasPrefix("/") else { return found }
        if let found, access.resolved(found.path) == access.resolved(reported) {
            return found
        }
        guard case let .data(data) = access.contents(ofFileAt: reported) else { return found }
        switch Self.read(data) {
        case let .success(definition):
            return Found(location: nil, path: reported, definition: definition, problem: nil)
        case let .failure(error):
            return Found(location: nil, path: reported, definition: nil, problem: error.reason)
        }
    }

    private static func read(_ data: Data) -> Result<LaunchdJobDefinition, LaunchdPlistError> {
        do {
            return .success(try LaunchdJobDefinition(plist: data))
        } catch {
            return .failure(error)
        }
    }
}
