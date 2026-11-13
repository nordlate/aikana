import Foundation

/// When files were last written.
public enum FileTimes {
    /// The most recent modification time among the files at `paths`. Files that are missing or cannot be read
    /// are skipped; `nil` when none could be read.
    public static func latestModification(of paths: [String]) -> Date? {
        paths.compactMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }
}
