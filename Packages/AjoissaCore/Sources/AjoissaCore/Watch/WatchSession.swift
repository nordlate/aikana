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
        /// Every job was looked at. `alerts` is what is worth telling the user now, empty unless the round was
        /// asked to announce. `saveProblem` says so if what was seen could not be remembered.
        case looked(config: Config, reports: [JobReport], alerts: [Alert], saveProblem: HistoryError?)
    }

    public let configURL: URL
    public let historyFile: HistoryFile
    private let watch: JobWatch

    public init(configURL: URL, historyFile: HistoryFile, watch: JobWatch) {
        self.configURL = configURL
        self.historyFile = historyFile
        self.watch = watch
    }

    /// Reads the config and the history, looks at every job, and saves what was seen.
    ///
    /// Both files are read anew every round, so a change to the config takes effect at the next round and
    /// two programs taking turns with one history file see each other's records.
    ///
    /// - Parameter announce: Whether the caller tells the user about problems and recoveries. Only then is it
    ///   worked out what is new to tell, and noted as told. A caller that only shows the state, such as the
    ///   command line tool, must leave this off, or it would use up what the app has yet to announce.
    public func round(now: Date, calendar: Calendar, announce: Bool = false) -> Outcome {
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
        let alerts = announce ? AlertPlanner.plan(reports: reports, history: &history) : []
        do {
            try historyFile.save(history)
        } catch {
            return .looked(config: config, reports: reports, alerts: alerts, saveProblem: error)
        }
        return .looked(config: config, reports: reports, alerts: alerts, saveProblem: nil)
    }
}
