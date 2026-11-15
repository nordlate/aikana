import AikanaCore
import SwiftUI

/// Every job: those that need a look first, under headings when there is more than one kind.
struct JobListView: View {
    let sections: [PanelSection]
    let saveProblem: String?
    let select: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            ForEach(sections) { section in
                if sections.count > 1 {
                    Text(section.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(section.rows) { row in
                    Button {
                        select(row.id)
                    } label: {
                        JobRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

/// One job in the list: its state, its name, what happened last, and what comes next.
struct JobRowView: View {
    let row: PanelRow
    @State private var isHovered = false

    private var report: JobReport { row.report }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.state.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(report.state.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.job.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(Self.detail(of: row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            let trailing = Self.trailing(of: report)
            Text(trailing.text)
                .font(.callout.weight(trailing.isState ? .semibold : .regular))
                .foregroundStyle(trailing.isState ? report.state.color : .secondary)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// The line under the name: "Ran today 3:04", "Due today 2:00 · last ran Sat 2:06",
    /// "Today 3:00 · its last run exited with code 1", with the machine after it when the list has several.
    static func detail(of row: PanelRow, now: Date = Date()) -> String {
        let report = row.report
        let lastRan = report.lastRun.map { "last ran \(Wording.recent($0, now: now))" } ?? "no run seen yet"
        let text: String
        switch report.state {
        case .ok, .running:
            if let lastRun = report.lastRun {
                text = "Ran \(Wording.recent(lastRun, now: now))"
            } else if report.source != nil {
                text = "No run seen yet"
            } else {
                text = Wording.sentence(report.reason)
            }
        case .missed, .waiting:
            if let due = report.expectedRun {
                text = "Due \(Wording.day(due, now: now)) · \(lastRan)"
            } else {
                text = Wording.sentence(report.reason)
            }
        case .failed:
            text = report.lastRun.map { Wording.sentence("\(Wording.recent($0, now: now)) · \(report.reason)") }
                ?? Wording.sentence(report.reason)
        case .stale, .unknown, .hostOffline:
            text = Wording.sentence(report.reason)
        }
        return row.hostName.map { "\(text) · \($0)" } ?? text
    }

    /// What is said at the right: the state when it is not plain "fine", else when the job runs next.
    static func trailing(of report: JobReport, now: Date = Date()) -> (text: String, isState: Bool) {
        guard report.state == .ok else {
            return (report.state.title, true)
        }
        if let interval = report.repeatInterval {
            return ("Every \(Wording.interval(interval))", false)
        }
        if let next = report.nextRun {
            return (Wording.sentence(Wording.day(next, now: now)), false)
        }
        return ("", false)
    }
}
