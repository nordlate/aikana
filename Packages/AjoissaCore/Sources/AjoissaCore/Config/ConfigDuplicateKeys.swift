import Foundation

/// Finds settings that are written twice in the same object.
///
/// A JSON parser keeps one of them and drops the other without a word, so half of what the user wrote would
/// silently not apply. This scans the text itself. It expects text that already parsed as JSON5.
enum DuplicateKeyScanner {
    struct Duplicate: Equatable {
        let line: Int
        let key: String

        var message: String {
            "\"\(key)\" is set twice in the same object, and only one of them would be used"
        }
    }

    static func duplicates(in data: Data) -> [Duplicate] {
        // Other encodings than UTF-8 contain zero bytes; scanning them byte by byte would be meaningless.
        guard !data.contains(0) else { return [] }
        var scan = Scan(bytes: [UInt8](data))
        scan.run()
        return scan.duplicates
    }

    private struct Scan {
        let bytes: [UInt8]
        var index = 0
        var line = 1
        /// The keys seen so far in each object being read; `nil` for a list.
        var open: [Set<String>?] = []
        /// Whether the next string or word is a key.
        var expectsKey = false
        var duplicates: [Duplicate] = []

        mutating func run() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Byte.slash, skipComment() {
                    continue
                }
                if byte == Byte.doubleQuote || byte == Byte.singleQuote {
                    use(readString(quote: byte))
                } else if Byte.isWord(byte) {
                    use(readWord())
                } else {
                    structure(byte)
                    index += 1
                }
            }
        }

        private mutating func structure(_ byte: UInt8) {
            switch byte {
            case Byte.newline:
                line += 1
            case Byte.openBrace:
                open.append([])
                expectsKey = true
            case Byte.openBracket:
                open.append(nil)
                expectsKey = false
            case Byte.closeBrace, Byte.closeBracket:
                open.removeLast(open.isEmpty ? 0 : 1)
                expectsKey = false
            case Byte.comma:
                expectsKey = open.last.map { $0 != nil } ?? false
            default:
                break
            }
        }

        /// Records `text` if it is in key position. Values are ignored.
        private mutating func use(_ text: String) {
            guard expectsKey, let last = open.indices.last, var keys = open[last] else { return }
            expectsKey = false
            if !keys.insert(text).inserted {
                duplicates.append(Duplicate(line: line, key: text))
            }
            open[last] = keys
        }

        /// Skips a `//` or `/* */` comment starting at `index`. Returns false when there is none.
        private mutating func skipComment() -> Bool {
            guard index + 1 < bytes.count else { return false }
            if bytes[index + 1] == Byte.slash {
                while index < bytes.count, bytes[index] != Byte.newline {
                    index += 1
                }
                return true
            }
            guard bytes[index + 1] == Byte.star else { return false }
            index += 2
            while index < bytes.count, !(bytes[index] == Byte.star && index + 1 < bytes.count && bytes[index + 1] == Byte.slash) {
                line += bytes[index] == Byte.newline ? 1 : 0
                index += 1
            }
            index = min(index + 2, bytes.count)
            return true
        }

        /// Reads a quoted string starting at `index` and returns what is between the quotes, escapes left as written.
        private mutating func readString(quote: UInt8) -> String {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] != quote {
                if bytes[index] == Byte.backslash {
                    index += 1
                }
                if index < bytes.count, bytes[index] == Byte.newline {
                    line += 1
                }
                index += 1
            }
            let end = min(index, bytes.count)
            index = min(index + 1, bytes.count)
            return String(bytes: bytes[start..<end], encoding: .utf8) ?? ""
        }

        /// Reads an unquoted key, number or keyword starting at `index`.
        private mutating func readWord() -> String {
            let start = index
            while index < bytes.count, Byte.isWord(bytes[index]) {
                index += 1
            }
            return String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
        }
    }

    private enum Byte {
        static let newline = UInt8(ascii: "\n")
        static let slash = UInt8(ascii: "/")
        static let star = UInt8(ascii: "*")
        static let backslash = UInt8(ascii: "\\")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
        static let comma = UInt8(ascii: ",")

        /// A byte that can be part of an unquoted key, a number or a keyword. Bytes above ASCII count, so that
        /// keys in other scripts are read as one word.
        static func isWord(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), 0x80...:
                true
            default:
                [UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(byte)
            }
        }
    }
}
