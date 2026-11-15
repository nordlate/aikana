import AikanaCore
import SwiftUI

/// The panel that opens from the menu bar item: the list of jobs, or one job in detail.
struct StatusMenuView: View {
    let model: WatchModel
    @State private var listHeight: CGFloat = 0
    @State private var loginProblem: String?

    static let panelWidth: CGFloat = 380
    /// The list grows with its jobs up to this, then scrolls.
    static let maxListHeight: CGFloat = 520
    /// The height of the parts that are not a list: a job in detail, a problem, the first look.
    static let otherHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            if let id = model.shownJobID, let report = model.report(withID: id) {
                JobDetailView(model: model, report: report) {
                    model.showJob(withID: nil)
                }
                .frame(height: Self.otherHeight)
            } else {
                header
                Divider()
                content
            }
            Divider()
            FooterView(model: model, loginProblem: loginProblem)
        }
        .frame(width: Self.panelWidth)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BadgeView(badge: model.badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let note = subtitle {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Group {
                if model.isLooking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .help("Look at every job now")
                    .accessibilityLabel("Refresh")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            PanelMenu(model: model, loginProblem: $loginProblem)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// "Checked just now · 5 others fine".
    private var subtitle: String? {
        let parts = [model.lookNote(), model.tally].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .starting:
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
        case let .configProblem(lines):
            ProblemView(
                title: model.configURL.path,
                lines: lines,
                hint: "Fix the file and save it; Aikana reads it again by itself."
            )
            .frame(height: Self.otherHeight)
        case let .historyProblem(message):
            ProblemView(title: "History", lines: [message], hint: nil)
                .frame(height: Self.otherHeight)
        case let .jobs(groups):
            if groups.isEmpty {
                ContentUnavailableView(
                    "No jobs configured",
                    systemImage: "clock",
                    description: Text("Add jobs to \(model.configURL.path)")
                )
                .frame(height: 220)
            } else {
                ScrollView {
                    JobListView(sections: model.sections, saveProblem: model.saveProblem) { model.showJob(withID: $0) }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            }
        }
    }
}

/// Everything at a glance, as a symbol on a tinted disc.
private struct BadgeView: View {
    let badge: WatchModel.Badge

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.22), in: Circle())
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch badge {
        case .looking: "clock"
        case .fine: "checkmark"
        case .attention, .failure: "exclamationmark"
        }
    }

    private var color: Color {
        switch badge {
        case .looking: .secondary
        case .fine: .green
        case .attention: .yellow
        case .failure: .red
        }
    }
}

/// A file that cannot be used, with everything that is wrong in it.
private struct ProblemView: View {
    let title: String
    let lines: [String]
    let hint: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
