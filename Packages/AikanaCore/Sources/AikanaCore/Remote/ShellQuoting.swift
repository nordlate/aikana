import Foundation

/// Turns a value into one word of a POSIX shell script.
///
/// Every value from the config that ends up in a script Aikana sends to another machine goes through this,
/// and nothing else does the job. Inside single quotes a POSIX shell treats no character specially, so the
/// only thing to handle is the single quote itself: it ends the quoted part, is written escaped, and the
/// quoted part starts again.
enum ShellQuoting {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a value can be put in a script at all. A script is text, read line by line: a value with a
    /// line break or a NUL in it is refused rather than quoted.
    static func isQuotable(_ value: String) -> Bool {
        !value.contains { $0.isNewline || $0 == "\0" }
    }
}
