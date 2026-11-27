import Foundation

// The plugin API. A plugin teaches Swiftty about one program or tool:
//
//   • `commands` — completions for its command line, as a declarative spec
//   • `probes`   — small shell snippets that report state before every prompt
//   • `pills`    — status pills above the prompt, built from that state
//
// Plugins are plain value types with no access to the UI or to Rex. Everything
// they know about the shell comes from `ShellSnapshot`, so the same plugin
// works for shells on this Mac and on remote servers.
//
// To add one: create a file in Plugins/Builtin, conform to `SwifttyPlugin`,
// and add it to `PluginRegistry.all`. GitPlugin.swift is a good one to copy.

protocol SwifttyPlugin: Sendable {
    /// Stable identifier, also the prefix of its probe keys ("git" → "git.branch").
    var id: String { get }
    /// Shown in Settings › Plugins.
    var name: String { get }
    var summary: String { get }
    /// SF Symbol shown in Settings.
    var symbol: String { get }

    /// Shell snippets run before every prompt, on the machine the shell runs on.
    var probes: [ShellProbe] { get }
    /// Completion specs for the commands this plugin knows.
    var commands: [CommandSpec] { get }
    /// Pills to show above the prompt for a shell in this state, in order.
    func pills(for shell: ShellSnapshot) -> [StatusPill]
}

extension SwifttyPlugin {
    var symbol: String { "puzzlepiece.extension" }
    var probes: [ShellProbe] { [] }
    var commands: [CommandSpec] { [] }
    func pills(for shell: ShellSnapshot) -> [StatusPill] { [] }
}

// MARK: - Shell state

/// A shell snippet whose standard output Swiftty reads before every prompt.
///
/// It runs inside the user's shell (zsh or bash), so it sees the shell's
/// variables and working directory. Rules:
///   • POSIX sh syntax only — the same text runs in zsh and bash.
///   • It must be fast (a few milliseconds): the prompt waits for it.
///   • It must not change shell state; it runs in a subshell.
///   • Print nothing when there is nothing to report. stderr is discarded.
struct ShellProbe: Sendable, Hashable {
    /// "<plugin id>.<name>", e.g. "git.branch". Read it back with `shell["git.branch"]`.
    var key: String
    var script: String

    init(_ key: String, _ script: String) {
        self.key = key
        self.script = script
    }
}

/// What Swiftty knows about a shell at its current prompt.
struct ShellSnapshot: Sendable, Equatable {
    /// The shell's working directory (absolute path on its machine).
    var cwd = ""
    /// The user's home directory on the shell's machine, when known.
    var home: String?
    /// False when the shell runs on a remote server.
    var isLocal = true
    /// Exit code of the last finished command.
    var lastExitCode: Int32?
    /// Probe output by key, trimmed.
    var values: [String: String] = [:]

    /// A probe's output, or nil when it printed nothing.
    subscript(key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }

    /// A probe's output split into non-empty lines.
    func lines(_ key: String) -> [String] {
        (values[key] ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `path` with the home directory shortened to "~".
    func abbreviated(_ path: String) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `path` with a leading "~" replaced by the home directory, made absolute against `cwd`.
    func resolved(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            guard let home else { return path }
            return home + path.dropFirst(1)
        }
        if path.hasPrefix("/") { return path }
        if path.isEmpty { return cwd }
        return cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
    }
}

// MARK: - Status pills

/// A small labelled capsule above the prompt (the folder, the git branch, …).
struct StatusPill: Sendable, Hashable, Identifiable {
    enum Tint: Sendable, Hashable {
        case secondary, accent, red, orange, yellow, green, blue, purple
    }

    /// Unique among all pills, e.g. "git.branch".
    var id: String
    /// SF Symbol name.
    var symbol: String
    var text: String
    var tint: Tint = .secondary
    /// Tooltip.
    var help: String?
}

// MARK: - Completions

/// One row in the completion list.
struct Completion: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case command, subcommand, option, file, folder, branch, environment, value
        /// Any SF Symbol.
        case symbol(String)

        var symbol: String {
            switch self {
            case .command: "terminal"
            case .subcommand: "chevron.forward.square"
            case .option: "minus.square"
            case .file: "doc"
            case .folder: "folder"
            case .branch: "arrow.triangle.branch"
            case .environment: "shippingbox"
            case .value: "textformat.abc"
            case .symbol(let name): name
            }
        }
    }

    /// What the list shows.
    var display: String
    /// The text that replaces the word being completed (already shell-escaped).
    var replacement: String
    var kind: Kind
    /// Dimmed text on the right: a short description.
    var detail: String?

    init(display: String, replacement: String, kind: Kind, detail: String? = nil) {
        self.display = display
        self.replacement = replacement
        self.kind = kind
        self.detail = detail
    }

    /// A plain word: inserted shell-escaped and followed by a space.
    init(_ word: String, kind: Kind = .value, detail: String? = nil) {
        self.init(display: word, replacement: ShellWords.escape(word) + " ", kind: kind, detail: detail)
    }
}

/// What a dynamic completion source is asked.
struct CompletionRequest: Sendable {
    /// The command and the words after it, up to the one being completed (unescaped).
    var words: [String]
    /// The partial word at the caret (unescaped). Results are filtered by it for you.
    var current: String
    var shell: ShellSnapshot
}

/// Where the values of an argument come from.
struct ArgumentSource: Sendable {
    enum Storage: Sendable {
        case files(directoriesOnly: Bool)
        case custom(@Sendable (CompletionRequest) async -> [Completion])
    }
    var storage: Storage

    /// Files and folders.
    static let files = ArgumentSource(storage: .files(directoriesOnly: false))
    /// Folders only.
    static let directories = ArgumentSource(storage: .files(directoriesOnly: true))

    /// A fixed list of words.
    static func oneOf(_ words: [String], kind: Completion.Kind = .value) -> ArgumentSource {
        ArgumentSource(storage: .custom { _ in words.map { Completion($0, kind: kind) } })
    }

    /// Words worked out from the shell's state. Return everything; Swiftty filters by what's typed.
    static func words(kind: Completion.Kind = .value,
                      _ words: @escaping @Sendable (ShellSnapshot) -> [String]) -> ArgumentSource {
        ArgumentSource(storage: .custom { request in words(request.shell).map { Completion($0, kind: kind) } })
    }

    /// Full control over the rows.
    static func custom(_ make: @escaping @Sendable (CompletionRequest) async -> [Completion]) -> ArgumentSource {
        ArgumentSource(storage: .custom(make))
    }
}

/// How a command's arguments complete: its subcommands, options and argument values.
///
///     CommandSpec("conda", "Package and environment manager", subcommands: [
///         CommandSpec("activate", "Activate an environment", arguments: [.words(kind: .environment) { envs($0) }]),
///         CommandSpec("deactivate", "Leave the environment", arguments: []),
///     ])
struct CommandSpec: Sendable {
    struct Option: Sendable {
        /// Every spelling, e.g. ["-n", "--name"].
        var names: [String]
        var summary: String?
        /// Set when the option takes a value, to complete it.
        var argument: ArgumentSource?

        init(_ names: String..., summary: String? = nil, argument: ArgumentSource? = nil) {
            self.names = names
            self.summary = summary
            self.argument = argument
        }
    }

    var name: String
    var aliases: [String]
    var summary: String?
    var subcommands: [CommandSpec]
    var options: [Option]
    /// Sources for positional arguments, merged in order.
    /// nil means "not specified": files, like the shell's default. `[]` means none.
    var arguments: [ArgumentSource]?

    init(_ name: String, _ summary: String? = nil, aliases: [String] = [],
         subcommands: [CommandSpec] = [], options: [Option] = [], arguments: [ArgumentSource]? = nil) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
        self.subcommands = subcommands
        self.options = options
        self.arguments = arguments
    }

    var allNames: [String] { [name] + aliases }
}
