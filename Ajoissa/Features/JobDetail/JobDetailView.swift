import AjoissaCore
import AppKit
import SwiftUI

/// One job: its schedule, its checks, what it has been through, and the end of its log.
struct JobDetailView: View {
    let model: WatchModel
    let report: JobReport
    let back: () -> Void

    /// How many past verdicts are listed.
    static let historyLimit = 10

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Label("Jobs", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(report.job.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Label(report.state.title, systemImage: report.state.symbolName)
                    .font(.callout)
                    .foregroundStyle(report.state.color)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Wording.sentence(report.reason))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    facts
                    if !report.checks.isEmpty {
                        section("Checks") { checks }
                    }
                    if !report.transitions.isEmpty {
                        section("History") { history }
                    }
                    ForEach(report.logPaths, id: \.self) { path in
                        LogSection(model: model, path: path, refreshedWith: report)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            fact("Schedule", report.schedule.isEmpty ? "None" : Wording.sentence(report.schedule))
            if let source = report.source {
                fact("Source", source)
            }
            if let status = report.sourceStatus {
                fact("Scheduler", Wording.sentence(status))
            }
            if report.lastRun != nil || report.source != nil {
                fact("Last run", report.lastRun.map { Wording.moment($0) } ?? "No run seen yet")
            }
            if let next = report.nextRun {
                fact("Next run", Wording.moment(next))
            }
        }
        .font(.callout)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checks: some View {
        ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: check.outcome.result.symbolName)
                    .foregroundStyle(check.outcome.result.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.label)
                        .font(.callout.monospaced())
                    Text(Wording.sentence(check.outcome.summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detail = check.outcome.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var history: some View {
        ForEach(Array(report.transitions.suffix(Self.historyLimit).reversed().enumerated()), id: \.offset) { _, transition in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: transition.state.symbolName)
                    .foregroundStyle(transition.state.color)
                    .accessibilityHidden(true)
                Text(Wording.moment(transition.date))
                    .monospacedDigit()
                Text("\(transition.state.title): \(transition.reason)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// The end of one log file, and a button that opens the file.
private struct LogSection: View {
    let model: WatchModel
    let path: String
    /// The log is read again whenever the job has been looked at again.
    let refreshedWith: JobReport
    @State private var log: WatchModel.LogText?

    /// How many lines of the end of the log are shown.
    static let lineLimit = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(path)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer()
                Button("Open Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                }
                .controlSize(.small)
                .disabled(log == .missing)
            }
            switch log {
            case nil:
                ProgressView()
                    .controlSize(.small)
            case .missing:
                note("There is no such file.")
            case let .unreadable(message):
                note(Wording.sentence(message))
            case let .text(text):
                if text.isEmpty {
                    note("The log is empty.")
                } else {
                    ScrollView(.horizontal) {
                        Text(Self.lastLines(of: text))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .task(id: refreshedWith) {
            log = await model.logText(at: path)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    static func lastLines(of text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reversed()
            .drop { $0.isEmpty }
            .prefix(lineLimit)
            .reversed()
            .joined(separator: "\n")
    }
}
