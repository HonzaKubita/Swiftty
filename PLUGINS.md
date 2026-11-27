# Writing a Swiftty plugin

A plugin teaches Swiftty about one tool. It can contribute three things, all optional:

| | What it is | Where it shows |
|---|---|---|
| **Completions** | A spec of the tool's subcommands, options and argument values | The list above the prompt |
| **Probes** | Small shell snippets that report state before every prompt | (invisible: they feed the other two) |
| **Status pills** | Labels built from that state | The row above the prompt (folder, git branch, …) |

Plugins are compiled into the app. Each one is a single Swift file in
[`Sources/Swiftty/Plugins/Builtin`](Sources/Swiftty/Plugins/Builtin), and a pull request is how one gets added.
[`GitPlugin.swift`](Sources/Swiftty/Plugins/Builtin/GitPlugin.swift) and
[`CondaPlugin.swift`](Sources/Swiftty/Plugins/Builtin/CondaPlugin.swift) are good ones to copy.

## A complete example

```swift
// Sources/Swiftty/Plugins/Builtin/NodePlugin.swift
import Foundation

struct NodePlugin: SwifttyPlugin {
    let id = "node"
    let name = "Node.js"
    let summary = "Shows the project's package name and completes npm scripts."
    let symbol = "hexagon"          // SF Symbol, shown in Settings › Plugins

    let probes = [
        // Prints one script name per line; nothing when there's no package.json.
        ShellProbe("node.scripts", #"[ -f package.json ] && sed -n '/"scripts"/,/}/{/"scripts"/!s/^ *"\([^"]*\)":.*/\1/p;}' package.json"#),
    ]

    func pills(for shell: ShellSnapshot) -> [StatusPill] {
        guard !shell.lines("node.scripts").isEmpty else { return [] }
        return [StatusPill(id: "node.project", symbol: "hexagon", text: "npm", tint: .green)]
    }

    var commands: [CommandSpec] {
        let scripts = ArgumentSource.words { $0.lines("node.scripts") }
        return [CommandSpec("npm", "Node package manager", subcommands: [
            CommandSpec("run", "Run a script", arguments: [scripts]),
            CommandSpec("install", "Install dependencies", aliases: ["i"], options: [
                .init("-D", "--save-dev", summary: "As a dev dependency"),
            ], arguments: []),
        ])]
    }
}
```

Then add it to the list in [`PluginRegistry.swift`](Sources/Swiftty/Plugins/PluginRegistry.swift):

```swift
nonisolated static let all: [any SwifttyPlugin] = [
    CorePlugin(), GitPlugin(), CondaPlugin(),
    NodePlugin(),
]
```

That's all: it appears in Settings › Plugins with a switch, its pills join the row in list order, and its
completions work on this Mac and on remote servers.

## Completions

A `CommandSpec` describes one command. The engine walks the words already typed down the spec's
`subcommands`, then offers what fits at the caret:

- **`subcommands`**: nested `CommandSpec`s. Their `summary` shows dimmed on the right of the row.
- **`options`**: offered once the word starts with `-`. Give an option an `argument` when it takes a value
  (`-n <env>`), and that value completes too.
- **`arguments`**: where positional values come from. Several sources are merged in order.
  - `nil` (the default) means "not specified": files, like a shell would.
  - `[]` means the command takes nothing.

Argument sources:

| Source | Completes |
|---|---|
| `.files`, `.directories` | Paths, on whichever machine the shell runs on |
| `.oneOf(["zsh", "bash"])` | A fixed list |
| `.words(kind: .branch) { shell in … }` | Words computed from the shell's state (usually probe output) |
| `.custom { request in … }` | Full control: return `[Completion]`, may be `async` |

Return everything you know; Swiftty filters by what's typed (prefix matches first, then matches anywhere),
escapes the inserted text for the shell, and removes duplicates. `sudo`, `env VAR=x` and similar wrappers in
front of your command are skipped for you.

## Probes

A probe is a line or two of shell whose standard output Swiftty reads **before every prompt**. That is what
keeps pills current: change branch, activate an environment, and the next prompt already knows.

```swift
ShellProbe("git.head", "git symbolic-ref --quiet --short HEAD 2>/dev/null")
```

Rules, because the prompt waits for every probe:

- **Be fast**: a few milliseconds. Read a file or a variable rather than starting a slow program
  (`conda env list` takes a second; reading `~/.conda/environments.txt` is instant).
- **POSIX `sh` syntax only.** The same text runs inside zsh and bash.
- **Print nothing when there's nothing to say.** stderr is discarded.
- **Don't change anything.** Probes run in a subshell and can't set the user's variables anyway.
- Name the key `<plugin id>.<name>`.

A plugin's probes run in order in one subshell, so a later one can reuse a variable an earlier one set
(prefix such variables with `_swiftty_`).

Read the output back from a `ShellSnapshot`:

```swift
shell["git.head"]          // String?, nil when the probe printed nothing
shell.lines("git.refs")    // [String], one per non-empty line
shell.cwd, shell.home, shell.isLocal, shell.lastExitCode
shell.abbreviated(path)    // "/Users/me/x" → "~/x"
```

Probes are the only way a plugin learns about the shell, which is why plugins work unchanged over ssh: the
output travels in the terminal stream itself (see [`ShellReport.swift`](Sources/Swiftty/Plugins/ShellReport.swift)).

## Status pills

`pills(for:)` is a pure function from a `ShellSnapshot` to the pills to show. Return `[]` when your tool isn't
in play; a pill that is always there is noise.

```swift
StatusPill(id: "conda.env", symbol: "shippingbox", text: name, tint: .green, help: "Conda environment \(name)")
```

`id` must be unique across plugins, `symbol` is an SF Symbol name, and `help` is the tooltip.

## Testing

[`Tests/SwifttyTests/CompletionTests.swift`](Tests/SwifttyTests/CompletionTests.swift) shows how to test a
plugin without a terminal: build a `ShellSnapshot` with the values your probes would report, and assert on
the completions and pills.

```bash
swift test
```

To try it in the app, build with `scripts/bundle.sh` and open a **new tab**: a shell learns its probes when it
starts.
