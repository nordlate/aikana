import Foundation

/// The end of a log file, to show a person.
public enum LogTail {
    /// How much of the end of a log is read.
    public static let defaultLimit: Int64 = 16000

    /// The last lines of the file at `path`, at most `limit` bytes of them. `nil` when there is no such file.
    ///
    /// When the file is longer than the limit, the first line read is most likely cut in two and is left out.
    public static func read(_ path: String, on host: any HostAccess, limit: Int64 = defaultLimit) throws(HostAccessError) -> String? {
        guard let file = try host.file(at: path) else {
            return nil
        }
        let start = max(0, file.size - limit)
        let data = try host.read(path, range: start..<file.size)
        // Bytes that are not valid text become replacement characters, as when a check reads the log.
        // swiftlint:disable:next optional_data_string_conversion
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let lineEnd = text.firstIndex(where: \.isNewline) {
            text = String(text[text.index(after: lineEnd)...])
        }
        return text
    }
}
