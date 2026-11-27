import Foundation

/// Works out the completion list for a command line.
///
/// The command name completes from the programs on the shell's PATH; its
/// arguments complete from the plugin `CommandSpec` for that command, or as
/// files when no plugin knows it.
struct CompletionEngine: Sendable {
    /// Specs by command name and alias.
    var specs: [String: CommandSpec]
    var executables = ExecutableIndex()

    static let limit = 80

    static let builtins = ["alias", "bg", "cd", "echo", "eval", "exec", "exit", "export", "fg", "history", "jobs",
                           "kill", "popd", "pushd", "set", "source", "time", "type", "unalias", "unset", "wait", "which"]
    /// Commands that run the command that follows them.
    static let wrappers: Set<String> = ["sudo", "command", "exec", "nohup", "time", "env", "xargs", "builtin", "noglob"]

    init(specs: [CommandSpec]) {
        var byName: [String: CommandSpec] = [:]
        for spec in specs {
            for name in spec.allNames where byName[name] == nil { byName[name] = spec }
        }
        self.specs = byName
    }

    struct Result: Sendable {
        /// The part of the text a completion replaces.
        var range: NSRange
        var items: [Completion]
    }

    /// - Parameter recentCommands: command names from history, newest first; used
    ///   when the shell's PATH can't be listed.
    func completions(text: String, caret: Int, shell: ShellSnapshot, host: ShellHost,
                     recentCommands: [String] = []) async -> Result {
        let line = CommandLine.parse(text, caret: caret)
        let words = Self.strippingWrappers(line.words)
        let current = line.current
        let items: [Completion]

        if words.isEmpty {
            if PathCompleter.looksLikePath(current) {
                items = await PathCompleter.complete(current, shell: shell, host: host, directoriesOnly: false)
            } else if current.isEmpty {
                items = []
            } else {
                items = await commandNames(matching: current, shell: shell, host: host, recent: recentCommands)
            }
        } else if let spec = specs[(words[0] as NSString).lastPathComponent] {
            let request = CompletionRequest(words: words, current: current, shell: shell)
            var found = await Self.complete(spec, request: request, host: host)
            if found.isEmpty, PathCompleter.looksLikePath(current) {
                found = await PathCompleter.complete(current, shell: shell, host: host, directoriesOnly: false)
            }
            items = found
        } else {
            items = await PathCompleter.complete(current, shell: shell, host: host, directoriesOnly: false)
        }

        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.replacement).inserted }
        return Result(range: line.range, items: Array(unique.prefix(Self.limit)))
    }

    /// Drop `sudo`, `env VAR=x` and friends, so the real command is first.
    static func strippingWrappers(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            let isAssignment = first.contains("=") && !first.hasPrefix("=") && !first.contains("/")
                && first.prefix(while: { $0 != "=" }).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isAssignment {
                rest = rest.dropFirst()
            } else if wrappers.contains(first) {
                rest = rest.dropFirst()
                // The wrapper's own options (sudo -u root …) aren't the command.
                while let next = rest.first, next.hasPrefix("-") { rest = rest.dropFirst() }
            } else {
                break
            }
        }
        return Array(rest)
    }

    private func commandNames(matching current: String, shell: ShellSnapshot, host: ShellHost,
                              recent: [String]) async -> [Completion] {
        var detail: [String: String] = [:]
        var names = Set(Self.builtins)
        for (name, spec) in specs {
            names.insert(name)
            if let summary = spec.summary { detail[name] = summary }
        }
        var path = shell["core.path"]
        if path == nil, host.isLocal { path = await LoginShell.path }
        if let path {
            names.formUnion(await executables.names(path: path, host: host))
        } else {
            names.formUnion(recent)
        }
        return names.filter { $0.hasPrefix(current) }
            .sorted { ($0.count, $0) < ($1.count, $1) }
            .map { Completion($0, kind: .command, detail: detail[$0]) }
    }

    // MARK: Specs

    struct Resolved {
        var spec: CommandSpec
        /// Set when the word at the caret is the value of this option.
        var optionValue: ArgumentSource?
    }

    /// Walk the words after the command name down the spec's subcommands.
    static func resolve(_ root: CommandSpec, arguments: ArraySlice<String>) -> Resolved {
        var spec = root
        var pending: ArgumentSource?
        for word in arguments {
            if pending != nil {
                pending = nil
            } else if word.hasPrefix("-"), word != "-" {
                pending = spec.options.first { $0.names.contains(word) }?.argument
            } else if let sub = spec.subcommands.first(where: { $0.allNames.contains(word) }) {
                spec = sub
            }
        }
        return Resolved(spec: spec, optionValue: pending)
    }

    static func complete(_ root: CommandSpec, request: CompletionRequest, host: ShellHost) async -> [Completion] {
        let resolved = resolve(root, arguments: request.words.dropFirst())
        let spec = resolved.spec
        let current = request.current

        if let source = resolved.optionValue {
            return await values(of: source, request: request, host: host)
        }
        if current.hasPrefix("-") {
            return spec.options.flatMap { option in
                option.names.filter { $0.hasPrefix(current) }
                    .map { Completion($0, kind: .option, detail: option.summary) }
            }
        }
        var items = spec.subcommands
            .filter { sub in sub.allNames.contains { $0.hasPrefix(current) } }
            .map { Completion($0.name, kind: .subcommand, detail: $0.summary) }
        let sources = spec.arguments ?? (spec.subcommands.isEmpty ? [.files] : [])
        for source in sources {
            items += await values(of: source, request: request, host: host)
        }
        return items
    }

    private static func values(of source: ArgumentSource, request: CompletionRequest, host: ShellHost) async -> [Completion] {
        switch source.storage {
        case .files(let directoriesOnly):
            return await PathCompleter.complete(request.current, shell: request.shell, host: host,
                                                directoriesOnly: directoriesOnly)
        case .custom(let make):
            return filter(await make(request), by: request.current)
        }
    }

    /// Rows that start with what's typed, then rows that merely contain it.
    static func filter(_ items: [Completion], by current: String) -> [Completion] {
        guard !current.isEmpty else { return items }
        let needle = current.lowercased()
        var starts: [Completion] = [], contains: [Completion] = []
        for item in items {
            let name = item.display.lowercased()
            if name.hasPrefix(needle) {
                starts.append(item)
            } else if needle.count >= 2, name.contains(needle) {
                contains.append(item)
            }
        }
        return starts + contains
    }
}
