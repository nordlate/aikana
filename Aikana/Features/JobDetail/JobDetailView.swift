import AikanaCore
import AppKit
import SwiftUI

/// One job: the verdict and its recent runs, the facts, its checks, the end of its log, and what it has been through.
struct JobDetailView: View {
    let model: WatchModel
    let report: JobReport
    let back: () -> Void
    @State private var contentHeight: CGFloat = 0

    /// How many past verdicts are listed.
    static let historyLimit = 10
    /// The detail grows with its content up to this, then scrolls.
    static let maxContentHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summary
                    if !report.checks.isEmpty {
                        Divider()
                        ChecksSection(checks: report.checks)
                    }
                    ForEach(report.logPaths, id: \.self) { path in
                        Divider()
                        LogSection(model: model, path: path, isLocal: model.isLocal(jobWithID: report.id), refreshedWith: report)
                    }
                    if !report.transitions.isEmpty {
                        Divider()
                        statusChanges
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))
        }
    }

    private var header: some View {
        ZStack {
            Text(report.job.name)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 80)
            HStack {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("Jobs")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Label(report.state.title, systemImage: report.state.symbolName)
                    .fontWeight(.semibold)
                    .foregroundStyle(report.state.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DetailWording.headline(of: report))
                    .font(.system(size: 15, weight: .semibold))
                if let subline = DetailWording.subline(of: report) {
                    Text(subline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let runs = DetailWording.shownRuns(of: report)
            if !runs.isEmpty {
                RunStrip(runs: runs)
            }
            facts
        }
        .font(.callout)
        .padding(16)
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            if report.lastRun != nil || report.source != nil {
                fact("Last run", Text(report.lastRun.map { Wording.sentence(Wording.day($0)) } ?? "No run seen yet"))
            }
            if let next = report.nextRun {
                fact("Next run", Text(Wording.sentence(Wording.day(next))))
            }
            fact("Schedule", Text(report.schedule.isEmpty ? "None" : Wording.sentence(report.schedule)))
            if let source = report.source {
                let parts = DetailWording.source(source)
                fact(parts.name, Text(parts.value).font(.callout.monospaced()))
            }
            if !report.sourceStatusParts.isEmpty {
                fact("State", stateText)
            } else if let status = report.sourceStatus {
                fact("State", Text(Wording.sentence(status)))
            }
        }
    }

    /// "Loaded, idle · last exit 1 · 41 runs", with the parts that are trouble in red.
    private var stateText: Text {
        report.sourceStatusParts.enumerated().reduce(Text("")) { text, item in
            let (index, part) = item
            let words = index == 0 ? Wording.sentence(part.text) : part.text
            let piece = Text(words).foregroundColor(part.isProblem ? .red : nil)
            return index == 0 ? piece : text + Text(" · ") + piece
        }
    }

    private func fact(_ name: String, _ value: Text) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
            value
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status changes

    private var statusChanges: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Status changes")
            ForEach(Array(report.transitions.suffix(Self.historyLimit).reversed().enumerated()), id: \.offset) { _, transition in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: transition.state.symbolName)
                        .foregroundStyle(transition.state.color)
                        .accessibilityHidden(true)
                    Text(Wording.sentence(Wording.day(transition.date)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(transition.state.title): \(Wording.shortReason(transition.reason))")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// A small heading over a part of the detail.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The recent runs as dots, oldest first: green for a run that was fine, red for one that failed, yellow for
/// one that was missed.
private struct RunStrip: View {
    let runs: [RunMark]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                mark(run)
                    .help("\(Wording.sentence(Wording.day(run.date))): \(word(run.outcome))")
            }
            Text(DetailWording.runsCaption(runs))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DetailWording.runsCaption(runs))
    }

    @ViewBuilder private func mark(_ run: RunMark) -> some View {
        switch run.outcome {
        case .ok: Circle().fill(.green).frame(width: 9, height: 9)
        case .failed: RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 9, height: 9)
        case .missed: Circle().strokeBorder(.yellow, lineWidth: 2).frame(width: 9, height: 9)
        }
    }

    private func word(_ outcome: RunMark.Outcome) -> String {
        switch outcome {
        case .ok: "on schedule"
        case .failed: "failed"
        case .missed: "missed"
        }
    }
}

/// The job's checks. When every one passed they fold into one line that opens on a click.
private struct ChecksSection: View {
    let checks: [JobReport.CheckReport]
    @State private var isOpen = false

    private var allPassed: Bool {
        checks.allSatisfy { $0.outcome.result == .passed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allPassed {
                Button {
                    withAnimation(.snappy) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.green)
                            .frame(width: 20)
                        Text(DetailWording.passedCaption(count: checks.count))
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                SectionTitle("Checks")
            }
            if !allPassed || isOpen {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    CheckRow(check: check)
                }
            }
        }
        .font(.callout)
        .padding(16)
    }
}

private struct CheckRow: View {
    let check: JobReport.CheckReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.outcome.result.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(check.outcome.result.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(check.kind)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Text(Wording.sentence(DetailWording.shortPath(check.target)))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(check.target)
                    Spacer(minLength: 6)
                    Text(DetailWording.checkResult(check.outcome.result))
                        .fontWeight(check.outcome.result == .passed ? .regular : .semibold)
                        .foregroundStyle(check.outcome.result == .passed ? .secondary : check.outcome.result.color)
                        .fixedSize()
                }
                if let message = DetailWording.checkMessage(check.outcome.result) {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = check.outcome.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
