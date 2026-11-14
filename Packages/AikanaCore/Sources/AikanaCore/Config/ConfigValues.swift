import Foundation

/// Parsers for the small value formats used in a config file.
enum ConfigValues {
    /// A whole number followed by a unit: `90s`, `30m`, `26h`, `2d`.
    static func duration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let multiplier = durationUnits[unit] else { return nil }
        guard let amount = wholeNumber(text.dropLast()) else { return nil }
        return TimeInterval(amount) * multiplier
    }

    /// A whole number followed by `B`, `KB`, `MB` or `GB` (powers of 1000): `500KB`, `10MB`.
    static func byteCount(_ text: String) -> Int64? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let amount = wholeNumber(digits), let multiplier = byteUnits[String(text.dropFirst(digits.count))] else {
            return nil
        }
        let (bytes, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : bytes
    }

    /// A 24-hour time: `02:00`, `23:59`.
    static func timeOfDay(_ text: String) -> TimeOfDay? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = wholeNumber(parts[0]), let minute = wholeNumber(parts[1]) else {
            return nil
        }
        return TimeOfDay(hour: Int(hour), minute: Int(minute))
    }

    private static let durationUnits: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    private static let byteUnits: [String: Int64] = ["B": 1, "KB": 1000, "MB": 1_000_000, "GB": 1_000_000_000]

    /// Digits only: no sign, no spaces, no decimals. At most nine digits, so later arithmetic cannot overflow.
    private static func wholeNumber(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }
}
