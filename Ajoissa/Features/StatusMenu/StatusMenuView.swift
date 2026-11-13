import AjoissaCore
import SwiftUI

/// The panel that opens from the menu bar item: the list of jobs, or one job in detail.
struct StatusMenuView: View {
    let model: WatchModel
    @State private var selectedJobID: String?

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            if let id = selectedJobID, let report = model.report(withID: id) {
                JobDetailView(model: model, report: report) {
                    selectedJobID = nil
                }
            } else {
                header
                Divider()
                content
            }
            Divider()
            FooterView(model: model)
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .onChange(of: model.reports.map(\.id)) { _, ids in
            // A job that left the config must not open by itself if it comes back.
            if let id = selectedJobID, !ids.contains(id) {
                selectedJobID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.menuBarSymbolName)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.headline)
                    .font(.headline)
                if let note = model.lookNote() {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.isLooking {
                ProgressView()
                    .controlSize(.small)
            }
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
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .starting:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .configProblem(lines):
            ProblemView(
                title: model.configURL.path,
                lines: lines,
                hint: "Fix the file and save it; Ajoissa reads it again by itself."
            )
        case let .historyProblem(message):
            ProblemView(title: "History", lines: [message], hint: nil)
        case let .jobs(groups):
            if groups.isEmpty {
                ContentUnavailableView(
                    "No jobs configured",
                    systemImage: "clock",
                    description: Text("Add jobs to \(model.configURL.path)")
                )
            } else {
                JobListView(groups: groups, saveProblem: model.saveProblem) { selectedJobID = $0 }
            }
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
