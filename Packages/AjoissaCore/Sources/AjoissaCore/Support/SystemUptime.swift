import Foundation

/// Since when this Mac has been awake without a break.
public enum SystemUptime {
    /// The later of the last wake from sleep and the last start. `nil` if neither can be read.
    public static func awakeSince() -> Date? {
        [time(named: "kern.waketime"), bootedAt()].compactMap { $0 }.max()
    }

    /// When this Mac last started.
    public static func bootedAt() -> Date? {
        time(named: "kern.boottime")
    }

    /// A kernel value that holds a moment as seconds and microseconds. Zero means it never happened.
    private static func time(named name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }
}
