import AjoissaCore
import SwiftUI

/// Every job, grouped by machine.
struct JobListView: View {
    let groups: [HostGroup]
    let saveProblem: String?
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let saveProblem {
                    Label(saveProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ForEach(groups) { group in
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.reports) { report in
                        Button {
                            select(report.id)
                        } label: {
                            JobRowView(report: report)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

/// One job in the list: name, state, last run and next expected run.
struct JobRowView: View {
    let report: JobReport
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: report.state.symbolName)
                .foregroundStyle(report.state.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(report.job.name)
                        .lineLimit(1)
                    Spacer()
                    Text(report.state.title)
                        .font(.callout)
                        .foregroundStyle(report.state.color)
                }
                if report.state != .ok {
                    Text(Wording.sentence(report.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let times = Self.times(of: report) {
                    Text(times)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// "Last run 02:00 · Next Sat 02:00", with whichever of the two there is. A job known only through its
    /// checks has no runs to see, so nothing is said about its last one.
    static func times(of report: JobReport, now: Date = Date()) -> String? {
        let parts = [
            report.lastRun.map { "Last run \(Wording.moment($0, now: now))" } ?? (report.source == nil ? nil : "No run seen yet"),
            report.nextRun.map { "Next \(Wording.moment($0, now: now))" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
