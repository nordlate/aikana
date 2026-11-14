import Foundation

/// A name that stays one harmless word wherever it ends up: as an argument to another program, or inside a
/// command line that a remote shell reads.
enum PlainName {
    /// Whether `text` is made of ASCII letters, digits, ".", "_" and "-" only and does not start with "-".
    /// Nothing a shell treats specially is allowed, and no leading "-" that a program could read as an option.
    ///
    /// - Parameter extra: Further characters to allow for this kind of name.
    static func isValid(_ text: String, extra: String = "") -> Bool {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" + extra
        return !text.isEmpty && !text.hasPrefix("-") && text.allSatisfy(allowed.contains)
    }
}
