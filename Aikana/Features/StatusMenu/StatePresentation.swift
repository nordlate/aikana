import AikanaCore
import SwiftUI

extension JobState {
    /// The state as a word to show.
    var title: String {
        switch self {
        case .ok: "OK"
        case .running: "Running"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .missed: "Missed"
        case .stale: "Stale"
        case .unknown: "Unknown"
        case .hostOffline: "Host offline"
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle"
        case .running: "play.circle.fill"
        case .waiting: "clock"
        case .failed: "xmark.circle.fill"
        case .missed: "exclamationmark.triangle.fill"
        case .stale: "questionmark.diamond.fill"
        case .unknown: "questionmark.circle"
        case .hostOffline: "wifi.slash"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .running: .blue
        case .failed: .red
        case .missed: .yellow
        case .stale, .hostOffline: .orange
        case .waiting, .unknown: .secondary
        }
    }
}

extension CheckOutcome.Result {
    var symbolName: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .couldNotRun: "questionmark.circle"
        case .skipped: "clock"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .couldNotRun, .skipped: .secondary
        }
    }
}

// `Host` alone is ambiguous with Foundation's, and the module shares its name with a type in it, so the
// heading hangs on the group.
extension HostGroup {
    /// The machine's name as a heading.
    var title: String {
        host.displayName
    }
}

enum Wording {
    /// A moment as a person would say it from `now`: "14:30" today, "Sat 14:30" within a week, else the date too.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 7
        if abs(days) < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A moment in the past as a person would say it: "just now", "5 min ago", or else `day(_:now:)`.
    static func recent(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let ago = now.timeIntervalSince(date)
        if ago < 60, ago > -60 {
            return "just now"
        }
        if ago > 0, ago < 60 * 60 {
            return "\(Int(ago / 60)) min ago"
        }
        return day(date, now: now, calendar: calendar)
    }

    /// A moment with its day: "today 14:30", "Sat 14:30" within a week, else the date too.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let text = moment(date, now: now, calendar: calendar)
        return calendar.isDate(date, inSameDayAs: now) ? "today \(text)" : text
    }

    /// An interval in the fewest words: "30 s", "15 min", "2 h", "1 h 30 min", "1 d".
    static func interval(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total) s"
        }
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        if days > 0, hours == 0, minutes == 0 {
            return "\(days) d"
        }
        let parts = [
            hours + days * 24 > 0 ? "\(hours + days * 24) h" : nil,
            minutes > 0 ? "\(minutes) min" : nil
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    /// A first letter in upper case, for a sentence that was written to follow a colon.
    static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
