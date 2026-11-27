import Foundation

/// The basics every shell gets: the folder and exit-status pills, and the
/// shell's own environment (home, PATH) that other features rely on.
struct CorePlugin: SwifttyPlugin {
    static let id = "core"
    var id: String { Self.id }
    let name = "Shell"
    let summary = "Folder and exit status pills, completion for cd and other built-ins."
    let symbol = "terminal"

    let probes = [
        ShellProbe("core.home", #"printf %s "$HOME""#),
        ShellProbe("core.path", #"printf %s "$PATH""#),
    ]

    let commands = [
        CommandSpec("cd", "Change folder", arguments: [.directories]),
        CommandSpec("pushd", "Change folder, remembering this one", arguments: [.directories]),
        CommandSpec("rmdir", "Remove empty folders", arguments: [.directories]),
        CommandSpec("mkdir", "Make folders", options: [.init("-p", summary: "Make parent folders too")],
                    arguments: [.directories]),
    ]

    func pills(for shell: ShellSnapshot) -> [StatusPill] {
        var pills: [StatusPill] = []
        if !shell.cwd.isEmpty {
            pills.append(StatusPill(id: "core.cwd", symbol: "folder", text: shell.abbreviated(shell.cwd), help: shell.cwd))
        }
        if let code = shell.lastExitCode, code != 0 {
            pills.append(StatusPill(id: "core.exit", symbol: "xmark.circle", text: "exit \(code)", tint: .red,
                                    help: "The last command failed with exit code \(code)"))
        }
        return pills
    }
}
