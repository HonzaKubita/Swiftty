import Foundation
import Testing
@testable import Swiftty

private let files: [String: [DirectoryEntry]] = [
    "/work": [
        .init(name: "src", isDirectory: true), .init(name: "My Folder", isDirectory: true),
        .init(name: "README.md", isDirectory: false), .init(name: ".hidden", isDirectory: false),
        .init(name: "readme.txt", isDirectory: false),
    ],
    "/work/My Folder/": [.init(name: "a (1).txt", isDirectory: false)],
    "/home/me/": [.init(name: "projects", isDirectory: true)],
    "/bin": [.init(name: "ls", isDirectory: false, isExecutable: true),
             .init(name: "lsof", isDirectory: false, isExecutable: true),
             .init(name: "notes", isDirectory: false)],
]

private let host = ShellHost(id: "test", isLocal: true) { directory, prefix, _ in
    files[directory]?.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
}

private func shell(_ values: [String: String] = [:]) -> ShellSnapshot {
    var all = ["core.path": "/bin"]
    all.merge(values) { $1 }
    return ShellSnapshot(cwd: "/work", home: "/home/me", isLocal: true, lastExitCode: nil, values: all)
}

private func complete(_ text: String, _ values: [String: String] = [:]) async -> [Completion] {
    let engine = CompletionEngine(specs: PluginRegistry.all.flatMap(\.commands))
    return await engine.completions(text: text, caret: (text as NSString).length, shell: shell(values), host: host).items
}

@Suite struct CommandLineTests {
    @Test func splitsWords() {
        let line = CommandLine.parse("git checkout ma", caret: 15)
        #expect(line.words == ["git", "checkout"])
        #expect(line.current == "ma")
        #expect(line.range == NSRange(location: 13, length: 2))
    }

    @Test func escapedSpaceStaysInOneWord() {
        let text = #"cd My\ Folder/su"#
        let line = CommandLine.parse(text, caret: (text as NSString).length)
        #expect(line.words == ["cd"])
        #expect(line.current == "My Folder/su")
        #expect(line.range.location == 3)
    }

    @Test func quotesGroupWords() {
        let text = #"cat "a b" 'c d' "e"#
        let line = CommandLine.parse(text, caret: (text as NSString).length)
        #expect(line.words == ["cat", "a b", "c d"])
        #expect(line.current == "e")
    }

    @Test func pipeStartsANewCommand() {
        let line = CommandLine.parse("ls | gre", caret: 8)
        #expect(line.words == [])
        #expect(line.current == "gre")
    }

    @Test func caretInTheMiddle() {
        let line = CommandLine.parse("cd src other", caret: 5)
        #expect(line.current == "sr")
        #expect(line.range == NSRange(location: 3, length: 2))
    }

    @Test func escaping() {
        #expect(ShellWords.escape("a (1).txt") == #"a\ \(1\).txt"#)
        #expect(ShellWords.escape("it's") == #"it\'s"#)
        #expect(ShellWords.escape("~x") == #"\~x"#)
        #expect(ShellWords.escape("origin/main") == "origin/main")
        #expect(ShellWords.escape("žluť") == "žluť")
    }

    @Test func wrappers() {
        #expect(CompletionEngine.strippingWrappers(["sudo", "-u", "git"]) == ["git"])
        #expect(CompletionEngine.strippingWrappers(["FOO=1", "env", "git", "status"]) == ["git", "status"])
        #expect(CompletionEngine.strippingWrappers(["sudo"]) == [])
    }
}

@Suite struct CompletionEngineTests {
    @Test func commandNamesComeFromPath() async {
        let items = await complete("ls")
        #expect(items.map(\.display) == ["ls", "lsof"])   // "notes" isn't executable
        #expect(items.first?.replacement == "ls ")
    }

    @Test func pluginCommandsAreOffered() async {
        let items = await complete("con")
        #expect(items.contains { $0.display == "conda" && $0.detail != nil })
    }

    @Test func cdListsOnlyFolders() async {
        let items = await complete("cd ")
        #expect(items.map(\.display) == ["My Folder/", "src/"])
        #expect(items.first?.replacement == #"My\ Folder/"#)
    }

    @Test func pathsAfterAnEscapedFolder() async {
        let items = await complete(#"cat My\ Folder/"#)
        #expect(items.map(\.replacement) == [#"My\ Folder/a\ \(1\).txt "#])
    }

    @Test func pathsIgnoreCaseAndHideDotfiles() async {
        #expect(await complete("cat read").map(\.display) == ["readme.txt", "README.md"])
        #expect(await complete("cat .").map(\.display) == [".hidden"])
    }

    @Test func tildeUsesTheShellsHome() async {
        let items = await complete("cd ~/pro")
        #expect(items.map(\.replacement) == ["~/projects/"])
    }

    @Test func unknownCommandsCompleteFiles() async {
        #expect(await complete("frobnicate s").map(\.display) == ["src/"])
    }

    @Test func gitSubcommands() async {
        let items = await complete("git sw")
        #expect(items.map(\.display) == ["switch"])
        #expect(items.first?.kind == .subcommand)
    }

    @Test func gitBranches() async {
        let refs = "refs/heads/main\nrefs/heads/feature/login\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/main"
        let state = ["git.head": "main", "git.refs": refs]
        #expect(await complete("git switch ", state).map(\.display) == ["main", "feature/login", "origin/main"])
        #expect(await complete("git switch log", state).map(\.display) == ["feature/login"])   // substring match
        #expect(await complete("git push ", state).map(\.display) == ["origin", "main", "feature/login"])
        #expect(await complete("git branch -d ", state).map(\.display) == ["main", "feature/login"])
        #expect(await complete("sudo git -C /tmp merge ma", state).map(\.display) == ["main", "origin/main"])
    }

    @Test func gitOptions() async {
        let items = await complete("git commit --a")
        #expect(items.map(\.display) == ["--all", "--amend"])
    }

    @Test func condaEnvironments() async {
        let state = ["conda.envs": "\n/opt/miniforge3\n/opt/miniforge3/envs/robot\n/Users/me/micromamba/envs/data\n"]
        #expect(await complete("conda activate ", state).map(\.display) == ["base", "robot", "data"])
        #expect(await complete("mamba install -n ro", state).map(\.display) == ["robot"])
        #expect(await complete("conda env remove --name d", state).map(\.display) == ["data"])
        #expect(await complete("conda deactivate ", state).isEmpty)
        #expect(await complete("conda act", state).map(\.display) == ["activate"])
    }
}

@Suite struct PillTests {
    @Test func gitAndCondaPills() {
        let plugins: [any SwifttyPlugin] = [CorePlugin(), GitPlugin(), CondaPlugin()]
        var s = shell(["git.head": "main", "conda.env": "robot"])
        s.cwd = "/home/me/projects"
        s.lastExitCode = 2
        let pills = plugins.flatMap { $0.pills(for: s) }
        #expect(pills.map(\.text) == ["~/projects", "exit 2", "main", "robot"])

        s.values = ["git.head": "detached:4ebafeb", "conda.env": "/opt/envs/thing"]
        s.lastExitCode = 0
        #expect(plugins.flatMap { $0.pills(for: s) }.map(\.text) == ["~/projects", "4ebafeb", "thing"])

        s.values = [:]
        #expect(plugins.flatMap { $0.pills(for: s) }.map(\.id) == ["core.cwd"])
    }

    @Test func probeKeysAreUniqueAndNamespaced() {
        var seen = Set<String>()
        for plugin in PluginRegistry.all {
            for probe in plugin.probes {
                #expect(probe.key.hasPrefix(plugin.id + "."))
                #expect(seen.insert(probe.key).inserted)
            }
        }
    }
}

@Suite struct ShellReportTests {
    static let probes = [
        ShellProbe("t.plain", "printf %s 'hello world'"),
        ShellProbe("t.lines", "printf 'a\\nb\\n'"),
        ShellProbe("t.empty", "true"),
        ShellProbe("t.fails", "echo oops >&2; return 3"),
        ShellProbe("t.shared", #"_x=1; printf %s "$PWD""#),
        ShellProbe("t.sees", #"printf %s "$_x""#),
    ]

    @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash"])
    func reportRoundTrips(shell: String) throws {
        let script = ShellReport.script(probes: Self.probes) + "printf before; _swiftty_report; printf after\n"
        let out = try #require(Subprocess.run(shell, ["-c", script], cwd: "/usr"))
        var scanner = ShellReportScanner()
        let result = scanner.feed(Data(out.utf8))
        #expect(String(decoding: result.passthrough, as: UTF8.self) == "beforeafter")
        #expect(result.reports == [[
            "t.plain": "hello world", "t.lines": "a\nb", "t.empty": "", "t.fails": "",
            "t.shared": "/usr", "t.sees": "1",
        ]])
    }

    @Test func scannerHandlesAnySplit() {
        let payload = Data("k\u{1f}v\u{1e}".utf8).base64EncodedString()
        let stream = Data("ab\u{1b}[31mred\u{1b}]7337;swiftty;\(payload)\u{07}cd\u{1b}]7;file:///x\u{07}\u{1b}".utf8)
        let plain = Data("ab\u{1b}[31mredcd\u{1b}]7;file:///x\u{07}\u{1b}".utf8)
        for cut in 0...stream.count {
            var scanner = ShellReportScanner()
            let a = scanner.feed(stream.prefix(cut))
            let b = scanner.feed(stream.dropFirst(cut))
            // A lone trailing ESC is held back until the next chunk decides what it starts.
            let c = scanner.feed(Data("x".utf8))
            #expect(a.passthrough + b.passthrough + c.passthrough == plain + Data("x".utf8), "cut at \(cut)")
            #expect(a.reports + b.reports == [["k": "v"]], "cut at \(cut)")
        }
    }

    @Test func realPluginsReportInARepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = Subprocess.run("/bin/sh", ["-c", "git init -q -b trunk && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x && git branch other"], cwd: dir.path)
        let probes = PluginRegistry.all.flatMap(\.probes)
        var values = await ShellReport.runLocally(probes: probes, cwd: dir.path)
        #expect(values["git.head"] == "trunk")
        #expect(values["git.refs"] == "refs/heads/other\nrefs/heads/trunk")
        #expect(values["core.home"] == NSHomeDirectory())

        _ = Subprocess.run("/bin/sh", ["-c", "git switch -q other"], cwd: dir.path)
        values = await ShellReport.runLocally(probes: probes, cwd: dir.path)
        #expect(values["git.head"] == "other")

        values = await ShellReport.runLocally(probes: probes, cwd: "/")
        #expect(values["git.head"] == "")
        #expect(values["git.refs"] == "")
    }

    @Test func historyFormats() {
        let zsh = Data(": 1700000000:0;git status\n: 1700000001:0;echo a\\\nb\nls\n".utf8)
        #expect(CommandHistory.parse(zsh) == ["git status", "echo a\nb", "ls"])
        let bash = Data("#1700000000\ngit status\n#1700000001\nls\n".utf8)
        #expect(CommandHistory.parse(bash) == ["git status", "ls"])
    }
}
