import Foundation

/// The end of a log file, to show a person.
public enum LogTail {
    /// How much of the end of a log is read.
    public static let defaultLimit: Int64 = 16000

    /// The last lines of the file at `path`, at most `limit` bytes of them. `nil` when there is no such file.
    ///
    /// When the file is longer than the limit, a first line that is cut in two is left out, unless it is all
    /// there is to show.
    public static func read(_ path: String, on host: any HostAccess, limit: Int64 = defaultLimit) throws(HostAccessError) -> String? {
        guard let file = try host.file(at: path) else {
            return nil
        }
        let start = max(0, file.size - limit)
        // One byte more than is shown tells whether the part shown starts at the start of a line.
        var data = try host.read(path, range: max(0, start - 1)..<file.size)
        let lineFeed = UInt8(ascii: "\n")
        if start > 0, !data.isEmpty {
            let startsALine = data.first == lineFeed
            data = data.dropFirst()
            if !startsALine, let lineEnd = data.firstIndex(of: lineFeed), data.index(after: lineEnd) < data.endIndex {
                data = data[data.index(after: lineEnd)...]
            }
        }
        // Bytes that are not valid text become replacement characters, as when a check reads the log.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
