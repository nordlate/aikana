import AikanaCore
import Foundation

/// The jobs in the panel, sorted by whether they want a look.
struct PanelSection: Identifiable, Equatable {
    enum Kind: CaseIterable {
        /// Failed, missed, unreadable for long, or on a machine that should be on and cannot be reached.
        case attention
        /// Ran as it should, is running, or still has time.
        case fine
        /// Not judged, or cannot be told right now.
        case unknown

        var title: String {
            switch self {
            case .attention: "Needs attention"
            case .fine: "Fine"
            case .unknown: "Unknown"
            }
        }
    }

    let kind: Kind
    let rows: [PanelRow]

    var id: Kind { kind }

    /// One section per kind that has jobs, the jobs in the order of their groups. Rows name their machine
    /// only when there is more than one.
    static func sections(of groups: [HostGroup]) -> [Self] {
        let named = groups.count > 1
        let rows = groups.flatMap { group in
            group.reports.map { PanelRow(report: $0, hostName: named ? group.host.displayName : nil) }
        }
        return Kind.allCases.compactMap { kind in
            let own = rows.filter { $0.report.panelKind == kind }
            return own.isEmpty ? nil : Self(kind: kind, rows: own)
        }
    }
}

/// One job in the panel list.
struct PanelRow: Identifiable, Equatable {
    let report: JobReport
    /// The machine the job runs on, when the list covers more than one.
    let hostName: String?

    var id: String { report.id }
}

extension JobReport {
    var panelKind: PanelSection.Kind {
        if state == .failed || needsAttention {
            return .attention
        }
        switch state {
        case .ok, .running, .waiting: return .fine
        case .failed, .missed, .stale, .unknown, .hostOffline: return .unknown
        }
    }
}
