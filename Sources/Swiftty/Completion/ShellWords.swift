import Foundation

/// The word at the caret and the words of the command before it.
struct CommandLine: Equatable {
    /// Unescaped words of the current simple command, before the one at the caret.
    var words: [String]
    /// The unescaped partial word at the caret.
    var current: String
    /// UTF-16 range of the partial word in the text, as typed (quotes and backslashes included).
    var range: NSRange

    /// Split `text` up to `caret` (a UTF-16 offset) the way a shell would:
    /// quotes and backslashes group words, and `|`, `;`, `&`, `(` start a new command.
    static func parse(_ text: String, caret: Int) -> CommandLine {
        let ns = text as NSString
        let upTo = ns.substring(to: max(0, min(caret, ns.length)))
        var words: [String] = []
        var current = ""
        var hasCurrent = false      // true for an empty quoted word like ""
        var start = 0
        var quote: Character?
        var escaped = false
        var offset = 0

        func endWord(at next: Int) {
            if hasCurrent { words.append(current) }
            current = ""
            hasCurrent = false
            start = next
        }

        for ch in upTo {
            let next = offset + ch.utf16.count
            defer { offset = next }
            if escaped {
                current.append(ch)
                escaped = false
            } else if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else {
                    current.append(ch)
                }
            } else if ch == "\\" {
                escaped = true
                hasCurrent = true
            } else if ch == "'" || ch == "\"" {
                quote = ch
                hasCurrent = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                endWord(at: next)
            } else if ch == "|" || ch == ";" || ch == "&" || ch == "(" {
                endWord(at: next)
                words = []
            } else {
                current.append(ch)
                hasCurrent = true
            }
        }
        return CommandLine(words: words, current: current, range: NSRange(location: start, length: offset - start))
    }
}

enum ShellWords {
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./,:@%+=~")

    /// `word` with a backslash before every character the shell would treat specially.
    static func escape(_ word: String) -> String {
        var out = ""
        for (i, scalar) in word.unicodeScalars.enumerated() {
            let special = scalar.isASCII && !safe.contains(scalar)
            // A leading "~" would expand to the home directory.
            if special || (i == 0 && scalar == "~") { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
