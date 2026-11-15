import AikanaCore
import AppKit
import SwiftUI

/// The end of one log file, with buttons that show it in Finder and open it.
struct LogSection: View {
    let model: WatchModel
    let path: String
    /// Whether the log is on this Mac, where it can be opened.
    let isLocal: Bool
    /// The log is read again whenever the job has been looked at again.
    let refreshedWith: JobReport
    @State private var log: WatchModel.LogText?

    /// How many lines of the end of the log are shown.
    static let lineLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionTitle("Log")
                Text(DetailWording.shortPath(path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer()
                if isLocal {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL(of: path)])
                    }
                    .buttonStyle(.link)
                    .disabled(log == .missing)
                    Button("Open Log") {
                        NSWorkspace.shared.open(Self.fileURL(of: path))
                    }
                    .disabled(log == .missing)
                }
            }
            .font(.callout)
            switch log {
            case nil:
                ProgressView()
                    .controlSize(.small)
            case .missing:
                note("There is no such file.")
            case let .unreadable(message):
                note(Wording.sentence(message))
            case let .text(text):
                let lines = Self.lastLines(of: text)
                if lines.isEmpty {
                    note("The log is empty.")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Self.styled(line)
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    note(DetailWording.linesCaption(count: lines.count))
                }
            }
        }
        .padding(16)
        .task(id: refreshedWith) {
            log = await model.logText(at: path, ofJobWithID: refreshedWith.id)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A line with its leading time stamp dimmed, and in red when it reads like an error.
    static func styled(_ line: String) -> Text {
        let color: Color? = looksLikeError(line) ? .red : nil
        guard let stamp = line.firstMatch(of: stampPattern) else {
            return Text(line).foregroundColor(color)
        }
        let rest = line[stamp.range.upperBound...]
        return Text(line[stamp.range]).foregroundColor(.secondary) + Text(rest).foregroundColor(color)
    }

    /// A time at the start of a line, with whatever date comes before it: "Sat 03:02:14 ", "2026-11-15 03:00:01 ".
    nonisolated(unsafe) static let stampPattern = /^\[?([A-Za-z]{3},? )?([\d\-\/.]{8,10}[ T])?\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?\]?\s+/

    /// Whether a line reads like an error.
    static func looksLikeError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["error", "fatal", "traceback", "exception"].contains { lower.contains($0) }
    }

    /// The file a path means. Only a leading `~/` is the home folder, as when the log is read.
    static func fileURL(of path: String) -> URL {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2)), directoryHint: .notDirectory)
        }
        return URL(fileURLWithPath: path)
    }

    /// The last lines of a log, with blank lines at its end dropped.
    static func lastLines(of text: String) -> [String] {
        Array(
            text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .reversed()
                .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(lineLimit)
                .reversed()
                .map(String.init)
        )
    }
}
