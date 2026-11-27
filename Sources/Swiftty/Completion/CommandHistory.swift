import Foundation

/// Commands the user ran: the shell's history file plus what was run in Swiftty.
@MainActor
final class CommandHistory {
    private(set) var entries: [String] = []   // oldest first, unique

    init(loadShellHistory: Bool = true) {
        if loadShellHistory { Task { await load() } }
    }

    private func load() async {
        let lines = await Task.detached { Self.readShellHistory() }.value
        var seen = Set(entries)
        var older: [String] = []
        for line in lines.reversed() where seen.insert(line).inserted { older.append(line) }
        entries = older.reversed() + entries
    }

    private nonisolated static func readShellHistory() -> [String] {
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["HISTFILE"], (env["ZDOTDIR"] ?? home) + "/.zsh_history", home + "/.bash_history"]
        let bashFirst = LoginShell.executable.hasSuffix("/bash")
        let ordered = bashFirst ? candidates.reversed() : candidates
        guard let data = ordered.lazy.compactMap({ $0 }).compactMap({ FileManager.default.contents(atPath: $0) }).first
        else { return [] }
        return parse(data)
    }

    /// Parse a zsh (plain or extended) or bash history file.
    nonisolated static func parse(_ data: Data) -> [String] {
        // zsh "metafies" bytes ≥ 0x83; undo it before decoding.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var meta = false
        for b in data {
            if meta { bytes.append(b ^ 32); meta = false } else if b == 0x83 { meta = true } else { bytes.append(b) }
        }
        var out: [String] = []
        var current = ""
        for raw in String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if current.isEmpty {
                // zsh extended history: ": 1700000000:0;command". bash timestamps: "#1700000000".
                if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                    line = String(line[line.index(after: semi)...])
                } else if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber), line.count > 1 {
                    continue
                }
            }
            if line.hasSuffix("\\") {
                current += line.dropLast() + "\n"
                continue
            }
            current += line
            if !current.isEmpty { out.append(current) }
            current = ""
        }
        return out
    }

    func add(_ command: String) {
        entries.removeAll { $0 == command }
        entries.append(command)
    }

    /// The newest command that starts with `prefix`.
    func suggestion(for prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        return entries.last { $0.hasPrefix(prefix) && $0 != prefix }
    }

    /// Command names (first words), newest first.
    func recentCommandNames(limit: Int = 500) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries.reversed() {
            guard let first = entry.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  seen.insert(first).inserted else { continue }
            out.append(first)
            if out.count >= limit { break }
        }
        return out
    }
}
