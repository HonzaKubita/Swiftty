import AppKit
import Foundation

/// Commands the user ran: the zsh history file plus this session's commands.
@MainActor
final class CommandHistory {
    private(set) var entries: [String] = []   // oldest first, unique

    init() {
        Task { await load() }
    }

    private func load() async {
        let path = ProcessInfo.processInfo.environment["HISTFILE"] ?? (NSHomeDirectory() + "/.zsh_history")
        let lines: [String] = await Task.detached {
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
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
                if current.isEmpty, line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                    line = String(line[line.index(after: semi)...])
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
        }.value
        var seen = Set<String>()
        var unique: [String] = []
        for l in lines.reversed() where seen.insert(l).inserted { unique.append(l) }
        entries = unique.reversed() + entries
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
}

struct Completion: Identifiable, Hashable {
    enum Kind: Hashable {
        case command, file, folder, branch, subcommand, history

        var symbol: String {
            switch self {
            case .command: "terminal"
            case .file: "doc"
            case .folder: "folder"
            case .branch: "arrow.triangle.branch"
            case .subcommand: "chevron.forward.square"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var id: String { "\(kind)-\(display)" }
    var display: String
    /// The text that replaces the token being completed.
    var replacement: String
    var kind: Kind
    var detail: String?
}

/// Where the caret's token sits in the prompt text.
struct TokenContext {
    var words: [String]          // words before the current one
    var current: String          // the partial word at the caret
    var range: NSRange           // UTF-16 range of `current` in the text
}

/// Swiftty's own completion engine: commands, paths, git, history.
@MainActor
final class CompletionEngine {
    private let history: CommandHistory
    private var executables: [String] = []
    private var branchCache: [String: (Date, [String])] = [:]

    static let builtins = ["cd", "echo", "export", "source", "alias", "unalias", "exit", "history", "pushd", "popd",
                           "set", "unset", "type", "which", "eval", "exec", "jobs", "fg", "bg", "kill", "wait", "time"]
    static let gitSubcommands = ["add", "bisect", "blame", "branch", "checkout", "cherry-pick", "clean", "clone", "commit",
                                 "config", "diff", "fetch", "grep", "init", "log", "merge", "mv", "pull", "push", "rebase",
                                 "reflog", "remote", "reset", "restore", "revert", "rm", "show", "stash", "status",
                                 "switch", "tag", "worktree"]
    static let gitBranchSubcommands: Set<String> = ["checkout", "switch", "merge", "rebase", "branch", "cherry-pick", "diff", "log", "reset", "show"]

    init(history: CommandHistory) {
        self.history = history
        Task { await loadExecutables() }
    }

    /// Read PATH from a login shell, then list every executable on it.
    private func loadExecutables() async {
        let names: [String] = await Task.detached {
            var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ShellIntegrationShell.path)
            p.arguments = ["-l", "-c", "print -rn -- $PATH"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let s = String(decoding: data, as: UTF8.self)
                if !s.isEmpty { path = s }
            }
            var set = Set<String>()
            let fm = FileManager.default
            for dir in path.split(separator: ":") {
                guard let items = try? fm.contentsOfDirectory(atPath: String(dir)) else { continue }
                for item in items where fm.isExecutableFile(atPath: "\(dir)/\(item)") { set.insert(item) }
            }
            return set.sorted()
        }.value
        executables = names
    }

    static func context(text: String, caret: Int) -> TokenContext {
        let ns = text as NSString
        let upTo = ns.substring(to: min(caret, ns.length))
        var words: [String] = []
        var current = ""
        var start = 0
        var quote: Character?
        var offset = 0
        for ch in upTo {
            let len = String(ch).utf16.count
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { words.append(current) }
                current = ""
                start = offset + len
            } else if ch == "|" || ch == ";" || ch == "&" {
                words = []
                current = ""
                start = offset + len
            } else {
                current.append(ch)
            }
            offset += len
        }
        return TokenContext(words: words, current: current, range: NSRange(location: start, length: offset - start))
    }

    /// Lists a directory on a remote machine; nil means use this Mac's file system.
    typealias RemoteLister = (_ dir: String, _ prefix: String) async -> [(name: String, isDir: Bool)]?

    func completions(text: String, caret: Int, cwd: String, remote: RemoteLister? = nil) async -> (TokenContext, [Completion]) {
        if let remote {
            return await remoteCompletions(text: text, caret: caret, cwd: cwd, lister: remote)
        }
        let ctx = Self.context(text: text, caret: caret)
        let cur = ctx.current
        var items: [Completion] = []

        if ctx.words.isEmpty {
            if cur.contains("/") || cur.hasPrefix(".") || cur.hasPrefix("~") {
                items = paths(for: cur, cwd: cwd, directoriesOnly: false)
            } else if !cur.isEmpty {
                let lower = cur.lowercased()
                let builtins = Self.builtins.filter { $0.hasPrefix(lower) }
                let exes = executables.lazy.filter { $0.hasPrefix(cur) }.prefix(200)
                var seen = Set<String>()
                for name in builtins + Array(exes) where seen.insert(name).inserted {
                    items.append(Completion(display: name, replacement: name + " ", kind: .command))
                }
                items.sort { ($0.display.count, $0.display) < ($1.display.count, $1.display) }
            }
        } else if ctx.words.first == "git" && ctx.words.count == 1 {
            items = Self.gitSubcommands.filter { $0.hasPrefix(cur) }
                .map { Completion(display: $0, replacement: $0 + " ", kind: .subcommand) }
        } else if ctx.words.first == "git", ctx.words.count >= 2, Self.gitBranchSubcommands.contains(ctx.words[1]), !cur.hasPrefix("-") {
            let branches = await branches(in: cwd)
            items = branches.filter { $0.hasPrefix(cur) }.map { Completion(display: $0, replacement: $0 + " ", kind: .branch) }
            items += paths(for: cur, cwd: cwd, directoriesOnly: false).prefix(20)
        } else {
            let dirsOnly = ["cd", "pushd", "rmdir"].contains(ctx.words.first ?? "")
            items = paths(for: cur, cwd: cwd, directoriesOnly: dirsOnly)
        }
        return (ctx, Array(items.prefix(60)))
    }

    /// Completion against another machine: paths come from Rex's list_dir, commands from history.
    private func remoteCompletions(text: String, caret: Int, cwd: String, lister: RemoteLister) async -> (TokenContext, [Completion]) {
        let ctx = Self.context(text: text, caret: caret)
        let cur = ctx.current
        if ctx.words.isEmpty, !cur.isEmpty, !cur.contains("/"), !cur.hasPrefix("."), !cur.hasPrefix("~") {
            var seen = Set<String>()
            var items: [Completion] = []
            for entry in history.entries.reversed() {
                guard let first = entry.split(separator: " ").first.map(String.init), first.hasPrefix(cur),
                      seen.insert(first).inserted else { continue }
                items.append(Completion(display: first, replacement: first + " ", kind: .command))
            }
            for b in Self.builtins where b.hasPrefix(cur) && seen.insert(b).inserted {
                items.append(Completion(display: b, replacement: b + " ", kind: .command))
            }
            return (ctx, Array(items.prefix(60)))
        }
        if ctx.words.first == "git" && ctx.words.count == 1 {
            return (ctx, Self.gitSubcommands.filter { $0.hasPrefix(cur) }.map { Completion(display: $0, replacement: $0 + " ", kind: .subcommand) })
        }
        let dirsOnly = ["cd", "pushd", "rmdir"].contains(ctx.words.first ?? "")
        var raw = cur
        if raw.hasPrefix("'") || raw.hasPrefix("\"") { raw.removeFirst() }
        raw = raw.replacingOccurrences(of: "\\ ", with: " ")
        let dirPart: String, prefix: String
        if let slash = raw.lastIndex(of: "/") {
            dirPart = String(raw[...slash])
            prefix = String(raw[raw.index(after: slash)...])
        } else {
            dirPart = ""
            prefix = raw
        }
        let dir = dirPart.isEmpty ? cwd : (dirPart.hasPrefix("/") || dirPart.hasPrefix("~") ? dirPart : (cwd as NSString).appendingPathComponent(dirPart))
        guard let entries = await lister(dir, prefix) else { return (ctx, []) }
        let showHidden = prefix.hasPrefix(".")
        let items = entries
            .filter { (showHidden || !$0.name.hasPrefix(".")) && (!dirsOnly || $0.isDir) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { e in
                let escaped = e.name.replacingOccurrences(of: " ", with: "\\ ")
                return Completion(display: e.name + (e.isDir ? "/" : ""), replacement: dirPart + escaped + (e.isDir ? "/" : " "),
                                  kind: e.isDir ? .folder : .file)
            }
        return (ctx, Array(items.prefix(60)))
    }

    private func branches(in cwd: String) async -> [String] {
        if let (at, list) = branchCache[cwd], Date().timeIntervalSince(at) < 10 { return list }
        let list = await Git.branches(in: cwd)
        branchCache[cwd] = (Date(), list)
        return list
    }

    private func paths(for token: String, cwd: String, directoriesOnly: Bool) -> [Completion] {
        var raw = token
        if raw.hasPrefix("'") || raw.hasPrefix("\"") { raw.removeFirst() }
        raw = raw.replacingOccurrences(of: "\\ ", with: " ")
        let expanded = raw.hasPrefix("~") ? NSHomeDirectory() + raw.dropFirst() : raw
        let dirPart: String
        let prefix: String
        if let slash = expanded.lastIndex(of: "/") {
            dirPart = String(expanded[...slash])
            prefix = String(expanded[expanded.index(after: slash)...])
        } else {
            dirPart = ""
            prefix = expanded
        }
        let base = dirPart.hasPrefix("/") ? dirPart : (cwd as NSString).appendingPathComponent(dirPart)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "." : base) else { return [] }
        let typedDir = token.hasPrefix("~") ? "~" + String(dirPart.dropFirst(NSHomeDirectory().count)) : dirPart
        var out: [Completion] = []
        let showHidden = prefix.hasPrefix(".")
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard name.hasPrefix(prefix) || (prefix.isEmpty), showHidden || !name.hasPrefix(".") else { continue }
            if !prefix.isEmpty && !name.lowercased().hasPrefix(prefix.lowercased()) { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isDir)
            if directoriesOnly && !isDir.boolValue { continue }
            let escaped = name.replacingOccurrences(of: " ", with: "\\ ")
            out.append(Completion(
                display: name + (isDir.boolValue ? "/" : ""),
                replacement: typedDir + escaped + (isDir.boolValue ? "/" : " "),
                kind: isDir.boolValue ? .folder : .file))
        }
        return out
    }
}

enum ShellIntegrationShell {
    static var path: String { ShellIntegration.userShell }
}
