import AjoissaCore
import AppKit
import ServiceManagement
import SwiftUI

/// The bottom of the panel: the version and the menu.
struct FooterView: View {
    let model: WatchModel
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        HStack {
            Text(problem ?? "Ajoissa \(AjoissaCore.version)")
                .font(.caption)
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
            Spacer()
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
                Button("Quit Ajoissa") {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Something the user should know about a switch in the menu.
    private var problem: String? {
        if let loginProblem {
            return loginProblem
        }
        if model.notificationsEnabled, model.notificationsRefused {
            return "Notifications are switched off for Ajoissa in System Settings"
        }
        return nil
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
