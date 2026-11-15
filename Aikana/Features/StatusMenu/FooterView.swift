import AikanaCore
import AppKit
import ServiceManagement
import SwiftUI

/// The bottom of the panel: whether notifications reach the user, and how to change that.
struct FooterView: View {
    let model: WatchModel
    /// Why Open at Login could not be changed, shown until it can.
    let loginProblem: String?

    var body: some View {
        HStack(spacing: 8) {
            if let loginProblem {
                Label(loginProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Image(systemName: isOn ? "bell" : "bell.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(isOn ? "Notifications are on" : "Notifications are off")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !model.notificationsEnabled {
                    Button("Turn On") {
                        model.notificationsEnabled = true
                    }
                    .buttonStyle(.link)
                } else if model.notificationsRefused {
                    Button("Open Settings", action: openNotificationSettings)
                        .buttonStyle(.link)
                        .help("Notifications are switched off for Aikana in System Settings")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isOn: Bool {
        model.notificationsEnabled && !model.notificationsRefused
    }

    /// Opens Aikana's page in the Notifications settings, or the Notifications settings when there is none.
    private func openNotificationSettings() {
        var address = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier {
            address += "?id=\(id)"
        }
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The menu at the top of the panel: files, switches and quitting.
struct PanelMenu: View {
    let model: WatchModel
    @Binding var loginProblem: String?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            Button("Open Config File") {
                openConfig()
            }
            Button("Reveal History Folder") {
                reveal(model.historyURL)
            }
            Divider()
            Toggle("Notifications", isOn: Binding(get: { model.notificationsEnabled }, set: { model.notificationsEnabled = $0 }))
            Toggle("Notify When Fine Again", isOn: Binding(get: { model.notifiesRecovery }, set: { model.notifiesRecovery = $0 }))
                .disabled(!model.notificationsEnabled)
            Toggle("Open at Login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            Divider()
            Text("Aikana \(AikanaCore.version)")
            Button("Quit Aikana") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Menu")
    }

    /// Opens the config file, or shows where it should be when there is none yet.
    private func openConfig() {
        if FileManager.default.fileExists(atPath: model.configURL.path) {
            NSWorkspace.shared.open(model.configURL)
        } else {
            reveal(model.configURL)
        }
    }

    /// Shows a file in Finder, or the nearest folder above it that exists.
    private func reveal(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.path != "/" {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func setOpensAtLogin(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginProblem = nil
        } catch {
            loginProblem = "Open at Login could not be changed: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
