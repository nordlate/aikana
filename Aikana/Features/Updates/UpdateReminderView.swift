import SwiftUI

/// A line above the footer when a newer version was found in the background and is waiting to be installed.
struct UpdateReminderView: View {
    let version: String
    let show: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Aikana \(version) is available")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Install…", action: show)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
