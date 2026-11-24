import Foundation
import Observation
import Sparkle

/// Keeps Aikana up to date through Sparkle: checks for a newer release, and offers to install it.
///
/// Only Release builds have one, and never while the app hosts tests: a Debug build must not replace itself
/// with a release, and a test run must not reach the network. The feed and the public key come from
/// `Info.plist` (`SUFeedURL`, `SUPublicEDKey`).
@MainActor
@Observable
final class Updater: NSObject {
    /// A user default that points the updater at another feed, to try an update against a local one.
    static let feedOverrideKey = "UpdateFeedURL"

    /// Whether "Check for Updates…" can be used now (not while a check or an update is under way).
    private(set) var canCheck = false
    /// A newer version Sparkle found on its own and is waiting to show, until the user looks at it.
    private(set) var waitingVersion: String?
    /// Whether Sparkle looks for updates by itself, once a day.
    ///
    /// Sparkle owns this setting and can change it without going through here (its own question on a later
    /// launch, or the user default), so the value shown is a mirror kept up to date by observing Sparkle.
    var checksAutomatically: Bool {
        get { checksAutomaticallyValue }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            checksAutomaticallyValue = newValue
        }
    }

    private var checksAutomaticallyValue = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var checksAutomaticallyObservation: NSKeyValueObservation?

    /// The updater for this build, or `nil` when this build must not update itself.
    static func forThisBuild(hostingTests: Bool) -> Updater? {
        #if DEBUG
        return nil
        #else
        return hostingTests ? nil : Updater()
        #endif
    }

    private override init() {
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheck = updater.canCheckForUpdates
            }
        }
        checksAutomaticallyObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.checksAutomaticallyValue = updater.automaticallyChecksForUpdates
            }
        }
        controller.startUpdater()
    }

    /// Looks for an update now and shows the result; brings a waiting update to the front.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// A menu bar app has no Dock icon to bounce, so an update found in the background is shown in the panel
    /// instead of in a window that could open behind others.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate && !state.userInitiated {
                waitingVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            waitingVersion = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            waitingVersion = nil
        }
    }
}
