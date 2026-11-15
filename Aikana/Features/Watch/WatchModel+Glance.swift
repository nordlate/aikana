import AikanaCore
import Foundation

extension WatchModel {
    // MARK: - At a glance

    var reports: [JobReport] {
        if case let .jobs(groups) = content {
            return groups.flatMap(\.reports)
        }
        return []
    }

    func report(withID id: String) -> JobReport? {
        reports.first { $0.id == id }
    }

    /// How long a look may take before the panel says that it is still under way.
    static let slowLook: TimeInterval = 120

    /// When the latest look was, or that one has been under way for long: a look can wait on a disk that
    /// does not answer, and what is shown is then older than it seems.
    func lookNote(now: Date = Date()) -> String? {
        if let lookingSince, now.timeIntervalSince(lookingSince) >= Self.slowLook {
            return "Still looking since \(Wording.moment(lookingSince, now: now)); what is shown may be out of date"
        }
        return lastLooked.map { "Checked \(Wording.recent($0, now: now))" }
    }

    /// The jobs as the panel lists them.
    var sections: [PanelSection] {
        if case let .jobs(groups) = content {
            return PanelSection.sections(of: groups)
        }
        return []
    }

    /// Everything at a glance, as the badge in the panel and the symbol in the menu bar show it.
    enum Badge: Equatable {
        case looking
        case fine
        case attention
        case failure
    }

    /// A config or history that cannot be used, or a history that cannot be saved, needs attention as much as
    /// a job does.
    var badge: Badge {
        switch content {
        case .starting:
            .looking
        case .configProblem, .historyProblem:
            .attention
        case .jobs:
            switch OverallStatus(reports: reports) {
            case .allFine: saveProblem == nil ? .fine : .attention
            case .needsAttention: .attention
            case .failure: .failure
            }
        }
    }

    var menuBarSymbolName: String {
        switch badge {
        case .looking: "clock"
        case .fine: "clock.badge.checkmark"
        case .attention: "clock.badge.exclamationmark"
        case .failure: "clock.badge.xmark"
        }
    }

    /// The state of everything in one line.
    var headline: String {
        switch content {
        case .starting:
            return "Looking…"
        case .configProblem:
            return "The config file cannot be used"
        case .historyProblem:
            return "The history file cannot be used"
        case .jobs:
            let reports = reports
            if reports.isEmpty {
                return "No jobs configured"
            }
            let attention = reports.count { $0.panelKind == .attention }
            switch attention {
            case 0: return "Everything is fine"
            case 1: return "1 job needs attention"
            default: return "\(attention) jobs need attention"
            }
        }
    }

    /// How the rest of the jobs are, after the headline: "5 others fine", "7 jobs", "6 fine, 1 unknown".
    var tally: String? {
        let reports = reports
        guard !reports.isEmpty else { return nil }
        let attention = reports.count { $0.panelKind == .attention }
        let fine = reports.count { $0.panelKind == .fine }
        let unknown = reports.count { $0.panelKind == .unknown }
        if unknown == 0 {
            if attention == 0 {
                return reports.count == 1 ? "1 job" : "\(reports.count) jobs"
            }
            return switch fine {
            case 0: nil
            case 1: "1 other fine"
            default: "\(fine) others fine"
            }
        }
        return fine == 0 ? "\(unknown) unknown" : "\(fine) fine, \(unknown) unknown"
    }
}
