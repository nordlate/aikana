import AjoissaCore
import SwiftUI

/// The panel that opens from the menu bar item. A placeholder until jobs are read from a config file.
struct StatusMenuView: View {
    static let menuBarSymbolName = "clock.badge.checkmark"
    static let emptyStateTitle = "No jobs configured"

    var body: some View {
        VStack(alignment: .leading) {
            Text(Self.emptyStateTitle)
                .font(.headline)
            Text("Ajoissa \(AjoissaCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit Ajoissa") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(minWidth: Self.minimumPanelWidth, alignment: .leading)
    }

    private static let minimumPanelWidth: CGFloat = 240
}
