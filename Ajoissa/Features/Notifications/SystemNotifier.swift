import AjoissaCore
import AppKit
import UserNotifications

/// Shows announcements as system notifications, and hears about the ones that are clicked.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// The key under which a notification carries the job it is about.
    private nonisolated static let jobKey = "job"

    /// Called when a notification is clicked, with the job it is about, or `nil` when it is about several.
    var onOpen: ((String?) -> Void)?

    /// Starts listening for clicks. Without this, a clicked notification only brings the app forward.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks the user, the first time, whether Ajoissa may show notifications.
    /// - Returns: Whether it may.
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func deliver(_ announcement: Announcement) async {
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.body
        content.sound = .default
        if let jobID = announcement.jobID {
            content.userInfo = [Self.jobKey: jobID]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // A notification that cannot be shown is not worth failing over: the panel shows the same thing.
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let jobID = response.notification.request.content.userInfo[Self.jobKey] as? String
        await MainActor.run {
            onOpen?(jobID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Ajoissa has no window to show it in, so the banner is wanted even while the panel is open.
        [.banner, .list, .sound]
    }
}

/// Opens the panel under the menu bar icon, as a click on the icon would.
@MainActor
enum PanelOpener {
    static func open() {
        NSApp.activate()
        // MenuBarExtra offers no way to open its window. Its status item's button does, and a click on it
        // while the panel is open would close it.
        let windows = NSApp.windows
        if windows.contains(where: { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }) {
            return
        }
        for window in windows where window.className.contains("StatusBarWindow") {
            if let button = button(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }
}
