import Foundation

/// Collects every problem found while a config is read, so the user sees them all at once.
final class IssueCollector {
    private(set) var issues: [ConfigIssue] = []

    func add(_ path: String, _ message: String) {
        issues.append(ConfigIssue(path: path, message: message))
    }
}

/// Reads the settings of one object in the config, reports values of the wrong kind,
/// and at the end reports settings nobody asked for, which are usually typos.
struct ObjectReader {
    let path: String
    private let values: [String: Any]
    private let issues: IssueCollector
    private var unread: Set<String>

    init(path: String, values: [String: Any], issues: IssueCollector) {
        self.path = path
        self.values = values
        self.issues = issues
        unread = Set(values.keys)
    }

    func path(of key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    func has(_ key: String) -> Bool {
        values[key] != nil
    }

    /// The number of entries in a list setting, or 0 when it is missing or not a list.
    func count(of key: String) -> Int {
        (values[key] as? [Any])?.count ?? 0
    }

    func report(_ key: String, _ message: String) {
        issues.add(path(of: key), message)
    }

    /// Reports a problem with the object as a whole.
    func reportSelf(_ message: String) {
        issues.add(path, message)
    }

    /// Reports every setting that was never read. Call once, after reading everything that is allowed.
    func finish() {
        for key in unread.sorted() {
            report(key, "is not a known setting")
        }
    }

    mutating func string(_ key: String) -> String? {
        guard let raw = value(key) else { return nil }
        guard let text = raw as? String else {
            report(key, "must be a string")
            return nil
        }
        guard !text.isEmpty else {
            report(key, "must not be empty")
            return nil
        }
        return text
    }

    /// A string that is one line of ordinary text: no line breaks, tabs or other control characters.
    mutating func line(_ key: String) -> String? {
        guard let text = string(key) else { return nil }
        guard !Self.hasControlCharacters(text) else {
            report(key, "must be a single line without control characters")
            return nil
        }
        return text
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    mutating func requiredString(_ key: String) -> String? {
        guard has(key) else {
            report(key, "is required")
            return nil
        }
        return string(key)
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let raw = value(key) else { return nil }
        guard let number = raw as? NSNumber, Self.isBoolean(number) else {
            report(key, "must be true or false")
            return nil
        }
        return number.boolValue
    }

    mutating func integer(_ key: String) -> Int? {
        guard let raw = value(key) else { return nil }
        guard let number = raw as? NSNumber, !Self.isBoolean(number), let whole = Int(exactly: number.doubleValue) else {
            report(key, "must be a whole number")
            return nil
        }
        return whole
    }

    mutating func array(_ key: String) -> [Any]? {
        guard let raw = value(key) else { return nil }
        guard let list = raw as? [Any] else {
            report(key, "must be a list")
            return nil
        }
        return list
    }

    mutating func object(_ key: String) -> Self? {
        guard let raw = value(key) else { return nil }
        guard let nested = raw as? [String: Any] else {
            report(key, "must be an object")
            return nil
        }
        return Self(path: path(of: key), values: nested, issues: issues)
    }

    /// A duration such as `30m`. Zero is not accepted.
    mutating func duration(_ key: String) -> TimeInterval? {
        guard let text = string(key) else { return nil }
        guard let seconds = ConfigValues.duration(text), seconds > 0 else {
            report(key, "must be a duration such as \"90s\", \"30m\", \"26h\" or \"2d\"")
            return nil
        }
        return seconds
    }

    /// A 24-hour time such as `02:00`.
    mutating func timeOfDay(_ key: String) -> TimeOfDay? {
        guard let text = requiredString(key) else { return nil }
        guard let time = ConfigValues.timeOfDay(text) else {
            report(key, "must be a 24-hour time such as \"02:00\"")
            return nil
        }
        return time
    }

    /// The objects in a list setting, each with a path that names its position and, when it has one, its id.
    mutating func elements(_ key: String) -> [Self] {
        guard let list = array(key) else { return [] }
        let listPath = path(of: key)
        return list.enumerated().compactMap { index, raw in
            let position = "\(listPath)[\(index)]"
            guard let nested = raw as? [String: Any] else {
                issues.add(position, "must be an object")
                return nil
            }
            // Only a well-formed id goes into the location; anything else could garble the message.
            let id = (nested["id"] as? String).flatMap { ConfigParser.isIdentifier($0) ? $0 : nil }
            let label = id.map { "\(position) (\($0))" }
            return Self(path: label ?? position, values: nested, issues: issues)
        }
    }

    private mutating func value(_ key: String) -> Any? {
        unread.remove(key)
        return values[key]
    }

    /// JSON `true` and `false` arrive as numbers; this tells them apart from 1 and 0.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
