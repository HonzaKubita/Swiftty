import Foundation

/// Git: a pill with the current branch, and completion for git's commands,
/// branches and remotes.
struct GitPlugin: SwifttyPlugin {
    let id = "git"
    let name = "Git"
    let summary = "Shows the current branch and completes git commands, branches and remotes."
    let symbol = "arrow.triangle.branch"

    // Probes run in order in one subshell, so the second can use what the first found.
    let probes = [
        // The branch, or "detached:<commit>" when no branch is checked out. Nothing outside a repository.
        ShellProbe("git.head", """
            if _swiftty_git=$(git symbolic-ref --quiet --short HEAD 2>/dev/null); then printf %s "$_swiftty_git"
            elif _swiftty_git=$(git rev-parse --short HEAD 2>/dev/null); then printf 'detached:%s' "$_swiftty_git"
            fi
            """),
        // Every branch as a full ref name: refs/heads/main, refs/remotes/origin/main.
        ShellProbe("git.refs", """
            [ -n "$_swiftty_git" ] && git for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null | head -n 400
            """),
    ]

    func pills(for shell: ShellSnapshot) -> [StatusPill] {
        guard let head = shell["git.head"] else { return [] }
        if head.hasPrefix("detached:") {
            let commit = String(head.dropFirst("detached:".count))
            return [StatusPill(id: "git.head", symbol: "smallcircle.filled.circle", text: commit, tint: .orange,
                               help: "Detached HEAD at \(commit)")]
        }
        return [StatusPill(id: "git.head", symbol: "arrow.triangle.branch", text: head, help: "On branch \(head)")]
    }

    // MARK: Completion

    static func localBranchNames(_ shell: ShellSnapshot) -> [String] {
        shell.lines("git.refs").filter { $0.hasPrefix("refs/heads/") }.map { String($0.dropFirst("refs/heads/".count)) }
    }

    /// Remote branches as "origin/main".
    static func remoteBranchNames(_ shell: ShellSnapshot) -> [String] {
        shell.lines("git.refs").filter { $0.hasPrefix("refs/remotes/") && !$0.hasSuffix("/HEAD") }
            .map { String($0.dropFirst("refs/remotes/".count)) }
    }

    static func remoteNames(_ shell: ShellSnapshot) -> [String] {
        var names: [String] = []
        for ref in shell.lines("git.refs") where ref.hasPrefix("refs/remotes/") {
            let name = String(ref.dropFirst("refs/remotes/".count).prefix { $0 != "/" })
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    static let branches = ArgumentSource.words(kind: .branch) { localBranchNames($0) + remoteBranchNames($0) }
    static let localBranches = ArgumentSource.words(kind: .branch) { localBranchNames($0) }
    static let remotes = ArgumentSource.words(kind: .symbol("network")) { remoteNames($0) }

    var commands: [CommandSpec] {
        let b = Self.branches, local = Self.localBranches, remotes = Self.remotes
        return [CommandSpec("git", "Version control", subcommands: [
            CommandSpec("add", "Stage changes", options: [
                .init("-A", "--all", summary: "Stage everything"),
                .init("-p", "--patch", summary: "Choose hunks"),
            ], arguments: [.files]),
            CommandSpec("bisect", "Find the commit that broke something", subcommands: [
                CommandSpec("start", arguments: [b]), CommandSpec("good", arguments: [b]),
                CommandSpec("bad", arguments: [b]), CommandSpec("reset", arguments: []),
                CommandSpec("skip", arguments: []), CommandSpec("log", arguments: []),
            ]),
            CommandSpec("blame", "Who changed each line", arguments: [.files]),
            CommandSpec("branch", "List, create or delete branches", options: [
                .init("-d", "--delete", summary: "Delete a branch", argument: local),
                .init("-D", summary: "Delete a branch, even if unmerged", argument: local),
                .init("-m", "--move", summary: "Rename a branch", argument: local),
                .init("-a", "--all", summary: "List remote branches too"),
                .init("-u", "--set-upstream-to", summary: "Set the upstream", argument: b),
            ], arguments: [b]),
            CommandSpec("checkout", "Switch branches or restore files", options: [
                .init("-b", summary: "Create and switch to a new branch"),
                .init("-B", summary: "Create or reset a branch, then switch"),
            ], arguments: [b, .files]),
            CommandSpec("cherry-pick", "Apply commits from elsewhere", options: [
                .init("--continue"), .init("--abort"), .init("--skip"),
            ], arguments: [b]),
            CommandSpec("clean", "Remove untracked files", options: [
                .init("-n", "--dry-run", summary: "Only show what would go"),
                .init("-f", "--force"), .init("-d", summary: "Folders too"),
            ], arguments: [.files]),
            CommandSpec("clone", "Copy a repository", arguments: [.directories]),
            CommandSpec("commit", "Record changes", options: [
                .init("-m", "--message", summary: "Commit message"),
                .init("-a", "--all", summary: "Stage tracked changes first"),
                .init("--amend", summary: "Rewrite the last commit"),
                .init("--no-edit", summary: "Keep the message"),
            ], arguments: [.files]),
            CommandSpec("config", "Read or set options", options: [.init("--global"), .init("--local"), .init("--list")],
                        arguments: []),
            CommandSpec("diff", "Show changes", options: [
                .init("--staged", "--cached", summary: "What's staged"),
                .init("--stat", summary: "Summary only"),
                .init("--name-only", summary: "File names only"),
            ], arguments: [b, .files]),
            CommandSpec("fetch", "Download from a remote", options: [
                .init("--all", summary: "Every remote"), .init("-p", "--prune", summary: "Drop deleted branches"),
            ], arguments: [remotes]),
            CommandSpec("grep", "Search tracked files", arguments: [.files]),
            CommandSpec("init", "Create a repository", arguments: [.directories]),
            CommandSpec("log", "Show history", options: [
                .init("--oneline", summary: "One line per commit"), .init("--graph", summary: "Draw the branches"),
                .init("--stat", summary: "Changed files"), .init("-p", "--patch", summary: "With diffs"),
                .init("-n", summary: "Limit the number of commits"),
            ], arguments: [b, .files]),
            CommandSpec("merge", "Join branches", options: [
                .init("--no-ff", summary: "Always make a merge commit"), .init("--squash"),
                .init("--abort"), .init("--continue"),
            ], arguments: [b]),
            CommandSpec("mv", "Move or rename a file", arguments: [.files]),
            CommandSpec("pull", "Fetch and integrate", options: [
                .init("--rebase", summary: "Rebase instead of merging"), .init("--ff-only"),
            ], arguments: [remotes, b]),
            CommandSpec("push", "Upload to a remote", options: [
                .init("-u", "--set-upstream", summary: "Track the remote branch"),
                .init("--force-with-lease", summary: "Force, unless the remote moved"),
                .init("-f", "--force"), .init("--tags"),
            ], arguments: [remotes, local]),
            CommandSpec("rebase", "Replay commits on another base", options: [
                .init("-i", "--interactive", summary: "Edit the list of commits"),
                .init("--continue"), .init("--abort"), .init("--skip"), .init("--onto", argument: b),
            ], arguments: [b]),
            CommandSpec("reflog", "Where HEAD has been", arguments: []),
            CommandSpec("remote", "Manage remotes", subcommands: [
                CommandSpec("add", "Add a remote", arguments: []),
                CommandSpec("remove", "Remove a remote", aliases: ["rm"], arguments: [remotes]),
                CommandSpec("rename", "Rename a remote", arguments: [remotes]),
                CommandSpec("set-url", "Change a remote's URL", arguments: [remotes]),
                CommandSpec("show", "Describe a remote", arguments: [remotes]),
            ], options: [.init("-v", "--verbose", summary: "Show URLs")]),
            CommandSpec("reset", "Move HEAD, unstage", options: [
                .init("--hard", summary: "Discard changes"), .init("--soft", summary: "Keep changes staged"),
                .init("--mixed", summary: "Keep changes unstaged"),
            ], arguments: [b, .files]),
            CommandSpec("restore", "Restore files", options: [
                .init("--staged", summary: "Unstage"), .init("-s", "--source", summary: "From this commit", argument: b),
            ], arguments: [.files]),
            CommandSpec("revert", "Undo a commit with a new one", arguments: [b]),
            CommandSpec("rm", "Remove files", options: [.init("--cached", summary: "Keep the file, stop tracking it"), .init("-r")],
                        arguments: [.files]),
            CommandSpec("show", "Show a commit or file", arguments: [b, .files]),
            CommandSpec("stash", "Shelve changes", subcommands: [
                CommandSpec("push", "Shelve changes", arguments: [.files]),
                CommandSpec("pop", "Restore and drop the newest", arguments: []),
                CommandSpec("apply", "Restore, keep the stash", arguments: []),
                CommandSpec("list", "List stashes", arguments: []),
                CommandSpec("drop", "Delete a stash", arguments: []),
                CommandSpec("show", "Show a stash", arguments: []),
                CommandSpec("clear", "Delete every stash", arguments: []),
            ], options: [.init("-u", "--include-untracked", summary: "Untracked files too")]),
            CommandSpec("status", "Show the working tree", options: [.init("-s", "--short")], arguments: [.files]),
            CommandSpec("switch", "Switch branches", options: [
                .init("-c", "--create", summary: "Create and switch to a new branch"),
                .init("-d", "--detach", summary: "Check out a commit"),
            ], arguments: [b]),
            CommandSpec("tag", "List or create tags", options: [.init("-d", "--delete"), .init("-a", "--annotate")],
                        arguments: []),
            CommandSpec("worktree", "Manage working trees", subcommands: [
                CommandSpec("add", "Check a branch out elsewhere", arguments: [.directories, b]),
                CommandSpec("list", "List working trees", arguments: []),
                CommandSpec("remove", "Remove a working tree", arguments: [.directories]),
                CommandSpec("prune", "Clean up stale entries", arguments: []),
            ]),
        ], options: [.init("-C", summary: "Run as if started in this folder", argument: .directories), .init("--version")])]
    }
}
