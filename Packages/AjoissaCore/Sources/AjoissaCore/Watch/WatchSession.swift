import Foundation

/// One config file, one history file, and the watch that looks at the jobs: everything a round needs.
public struct WatchSession: Sendable {
    /// What one round came to.
    public enum Outcome: Sendable, Equatable {
        /// The config could not be used. Nothing was looked at and the history was left alone.
        case configProblem(ConfigError)
        /// The history could not be read. Nothing was looked at: judging without it would call every job
        /// unwatched, and saving would replace a file that may only need repair.
        case historyProblem(HistoryError)
        /// Every job was looked at. `saveProblem` says so if what was seen could not be remembered.
        case looked(config: Config, reports: [JobReport], saveProblem: HistoryError?)
    }

    public let configURL: URL
    public let historyFile: HistoryFile
    private let watch: LocalWatch

    public init(configURL: URL, historyFile: HistoryFile, watch: LocalWatch) {
        self.configURL = configURL
        self.historyFile = historyFile
        self.watch = watch
    }

    /// Reads the config and the history, looks at every job, and saves what was seen.
    ///
    /// Both files are read anew every round, so a change to the config takes effect at the next round and
    /// two programs taking turns with one history file see each other's records.
    public func round(now: Date, calendar: Calendar) -> Outcome {
        let config: Config
        do {
            config = try ConfigLoader.load(contentsOf: configURL)
        } catch {
            return .configProblem(error)
        }
        var history: History
        do {
            history = try historyFile.load()
        } catch {
            return .historyProblem(error)
        }
        let reports = watch.look(at: config, history: &history, now: now, calendar: calendar)
        do {
            try historyFile.save(history)
        } catch {
            return .looked(config: config, reports: reports, saveProblem: error)
        }
        return .looked(config: config, reports: reports, saveProblem: nil)
    }
}
