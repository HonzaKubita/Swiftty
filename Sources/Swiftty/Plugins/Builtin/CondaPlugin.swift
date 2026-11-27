import Foundation

/// Conda (and mamba / micromamba): a pill with the active environment, and
/// completion for commands and environment names.
struct CondaPlugin: SwifttyPlugin {
    let id = "conda"
    let name = "Conda"
    let summary = "Shows the active conda environment and completes conda and mamba commands and environment names."
    let symbol = "shippingbox"

    let probes = [
        ShellProbe("conda.env", #"printf %s "$CONDA_DEFAULT_ENV""#),
        // Conda keeps a list of every environment's folder here; reading it is instant
        // (`conda env list` takes a second). Then the folders micromamba uses.
        ShellProbe("conda.envs", #"""
            cat "$HOME/.conda/environments.txt" 2>/dev/null
            for d in "${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"/envs/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
            """#),
    ]

    func pills(for shell: ShellSnapshot) -> [StatusPill] {
        guard let env = shell["conda.env"] else { return [] }
        // An environment activated by path reports the whole path.
        let name = env.contains("/") ? (env as NSString).lastPathComponent : env
        return [StatusPill(id: "conda.env", symbol: "shippingbox", text: name, tint: .green,
                           help: "Conda environment \(env)")]
    }

    /// Environment names from the folders conda reported. A folder outside an
    /// "envs" directory is a conda installation itself: its "base" environment.
    static func environments(_ shell: ShellSnapshot) -> [String] {
        var names = ["base"]
        for path in shell.lines("conda.envs") {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent == "envs" else { continue }
            if !names.contains(url.lastPathComponent) { names.append(url.lastPathComponent) }
        }
        return names
    }

    var commands: [CommandSpec] {
        let envs = ArgumentSource.words(kind: .environment) { Self.environments($0) }
        let named: [CommandSpec.Option] = [
            .init("-n", "--name", summary: "Environment name", argument: envs),
            .init("-p", "--prefix", summary: "Environment folder", argument: .directories),
        ]
        let yes = CommandSpec.Option("-y", "--yes", summary: "Don't ask")
        let channel = CommandSpec.Option("-c", "--channel", summary: "Extra channel",
                                         argument: .oneOf(["conda-forge", "defaults", "bioconda", "pytorch", "nvidia"]))
        let subcommands = [
            CommandSpec("activate", "Activate an environment", arguments: [envs]),
            CommandSpec("deactivate", "Leave the active environment", arguments: []),
            CommandSpec("create", "Create an environment", options: named + [yes, channel,
                .init("--clone", summary: "Copy an environment", argument: envs),
                .init("-f", "--file", summary: "Read packages from a file", argument: .files),
            ], arguments: []),
            CommandSpec("install", "Install packages", options: named + [yes, channel,
                .init("-f", "--file", summary: "Read packages from a file", argument: .files),
            ], arguments: []),
            CommandSpec("remove", "Remove packages", aliases: ["uninstall"], options: named + [yes,
                .init("--all", summary: "Remove the whole environment"),
            ], arguments: []),
            CommandSpec("update", "Update packages", aliases: ["upgrade"], options: named + [yes, channel,
                .init("--all", summary: "Update everything"),
            ], arguments: []),
            CommandSpec("list", "List installed packages", options: named, arguments: []),
            CommandSpec("search", "Search for packages", options: [channel], arguments: []),
            CommandSpec("run", "Run a command in an environment", options: named),
            CommandSpec("env", "Manage environments", subcommands: [
                CommandSpec("list", "List environments", arguments: []),
                CommandSpec("create", "Create from an environment file", options: named + [
                    .init("-f", "--file", summary: "Environment file", argument: .files),
                ], arguments: []),
                CommandSpec("update", "Update from an environment file", options: named + [
                    .init("-f", "--file", summary: "Environment file", argument: .files),
                    .init("--prune", summary: "Remove packages no longer listed"),
                ], arguments: []),
                CommandSpec("remove", "Delete an environment", options: named + [yes], arguments: []),
                CommandSpec("export", "Write an environment file", options: named + [
                    .init("--from-history", summary: "Only what you asked for"),
                    .init("--no-builds", summary: "Leave out build strings"),
                ], arguments: []),
            ]),
            CommandSpec("info", "About this conda", options: [.init("-e", "--envs", summary: "List environments")], arguments: []),
            CommandSpec("config", "Change conda's settings", options: [
                .init("--show"), .init("--set"), .init("--add"), .init("--remove"),
            ], arguments: []),
            CommandSpec("clean", "Remove caches", options: [.init("-a", "--all"), yes], arguments: []),
            CommandSpec("init", "Set up your shell for conda", arguments: [.oneOf(["zsh", "bash", "fish"])]),
        ]
        return [
            CommandSpec("conda", "Package and environment manager", subcommands: subcommands),
            CommandSpec("mamba", "Fast conda", subcommands: subcommands),
            CommandSpec("micromamba", "Tiny conda", subcommands: subcommands),
        ]
    }
}
