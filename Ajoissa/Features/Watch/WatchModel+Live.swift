import AjoissaCore
import AppKit
import Foundation

extension WatchModel {
    /// The model for the real thing: this Mac, the user's config and history files.
    static func live() -> WatchModel {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let variables = ProcessInfo.processInfo.environment
        let configURL = ConfigLocation.resolve(explicitPath: nil, environment: variables, homeDirectory: home)
        let historyFile = HistoryFile(environment: variables, homeDirectory: home)
        let watch = JobWatch(
            homeDirectory: home,
            userID: getuid(),
            controlDirectory: home.appending(path: JobWatch.defaultControlDirectory)
        )
        let session = WatchSession(configURL: configURL, historyFile: historyFile, watch: watch)
        let notifier = SystemNotifier()
        let model = WatchModel(environment: Environment(
            configURL: configURL,
            historyURL: historyFile.url,
            round: { now in
                // Looking runs programs and reads files; it stays off the main thread.
                await Task.detached { session.round(now: now, calendar: .current, announce: true) }.value
            },
            configFingerprint: { fingerprint(of: configURL) },
            readLog: { path, host in
                await Task.detached { readLog(path, on: host, watch: watch) }.value
            },
            deliver: { await notifier.deliver($0) },
            requestNotificationPermission: { await notifier.requestPermission() },
            readSwitch: { UserDefaults.standard.object(forKey: $0) as? Bool },
            writeSwitch: { UserDefaults.standard.set($1, forKey: $0) }
        ))
        notifier.onOpen = { [weak model] jobID in
            model?.showJob(withID: jobID)
            PanelOpener.open()
        }
        if !isHostingTests {
            notifier.activate()
        }
        return model
    }

    nonisolated static func readLog(_ path: String, on host: WatchedHost, watch: JobWatch) -> LogText {
        do throws(HostAccessError) {
            return try watch.logTail(of: path, on: host).map(LogText.text) ?? .missing
        } catch {
            return .unreadable(error.message)
        }
    }

    /// The file's identity, size and time of writing, following links. Saving a file in any way changes one.
    nonisolated static func fingerprint(of url: URL) -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return "absent"
        }
        return "\(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// Yields each time the Mac wakes from sleep.
    static func systemWakes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                continuation.yield()
            }
            // The observer is only ever handed back to the notification center.
            nonisolated(unsafe) let token = observer
            continuation.onTermination = { _ in
                center.removeObserver(token)
            }
        }
    }

    /// Whether this process is a test run. The app is launched to host the tests, and must not then look at
    /// the user's jobs or write the user's history.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
