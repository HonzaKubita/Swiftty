import Foundation

struct DirectoryEntry: Sendable, Hashable {
    var name: String
    var isDirectory: Bool
    var isExecutable = false
}

/// The file system of the machine a shell runs on: this Mac, or a remote server through Rex.
struct ShellHost: Sendable {
    /// Identifies the machine (for caches).
    var id: String
    var isLocal: Bool
    /// Entries of `directory` whose names start with `prefix`; nil when it can't be read.
    var list: @Sendable (_ directory: String, _ prefix: String, _ limit: Int) async -> [DirectoryEntry]?

    static let local = ShellHost(id: "local", isLocal: true) { directory, prefix, limit in
        await Task.detached(priority: .userInitiated) { () -> [DirectoryEntry]? in
            let fm = FileManager.default
            let base = directory.isEmpty ? "/" : directory
            guard let names = try? fm.contentsOfDirectory(atPath: base) else { return nil }
            let wanted = prefix.lowercased()
            var out: [DirectoryEntry] = []
            for name in names where wanted.isEmpty || name.lowercased().hasPrefix(wanted) {
                let path = (base as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: path, isDirectory: &isDir)   // follows symlinks
                out.append(DirectoryEntry(name: name, isDirectory: isDir.boolValue,
                                          isExecutable: !isDir.boolValue && fm.isExecutableFile(atPath: path)))
                if out.count >= limit { break }
            }
            return out
        }.value
    }
}

/// Completes file and folder names.
enum PathCompleter {
    /// True when a word can only be a path.
    static func looksLikePath(_ word: String) -> Bool {
        word.contains("/") || word.hasPrefix(".") || word.hasPrefix("~")
    }

    static func complete(_ word: String, shell: ShellSnapshot, host: ShellHost,
                         directoriesOnly: Bool, limit: Int = 500) async -> [Completion] {
        // "src/ma" → folder "src/", name prefix "ma".
        let typedDir: String, prefix: String
        if let slash = word.lastIndex(of: "/") {
            typedDir = String(word[...slash])
            prefix = String(word[word.index(after: slash)...])
        } else if word == "~" {
            typedDir = "~/"
            prefix = ""
        } else {
            typedDir = ""
            prefix = word
        }
        let directory = shell.resolved(typedDir)
        guard let entries = await host.list(directory, prefix, limit) else { return [] }

        let showHidden = prefix.hasPrefix(".")
        let lower = prefix.lowercased()
        let matches = entries
            .filter { e in
                (showHidden || !e.name.hasPrefix("."))
                    && (!directoriesOnly || e.isDirectory)
                    && (lower.isEmpty || e.name.lowercased().hasPrefix(lower))
            }
            .sorted { a, b in
                // Names that match the typed case come first.
                let ea = a.name.hasPrefix(prefix), eb = b.name.hasPrefix(prefix)
                if ea != eb { return ea }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        let escapedDir = typedDir.hasPrefix("~")
            ? "~" + ShellWords.escape(String(typedDir.dropFirst()))
            : ShellWords.escape(typedDir)
        return matches.map { e in
            Completion(display: e.name + (e.isDirectory ? "/" : ""),
                       replacement: escapedDir + ShellWords.escape(e.name) + (e.isDirectory ? "/" : " "),
                       kind: e.isDirectory ? .folder : .file)
        }
    }
}

/// The names of the programs on a shell's PATH, listed once per PATH.
actor ExecutableIndex {
    private var cache: [String: (path: String, task: Task<[String], Never>)] = [:]

    func names(path: String, host: ShellHost) async -> [String] {
        if let hit = cache[host.id], hit.path == path { return await hit.task.value }
        let task = Task.detached(priority: .userInitiated) { () -> [String] in
            var seen = Set<String>()
            let dirs = path.split(separator: ":").map(String.init).filter { seen.insert($0).inserted }
            let found = await withTaskGroup(of: [String].self) { group in
                for dir in dirs {
                    group.addTask {
                        let entries = await host.list(dir, "", 5000) ?? []
                        // Rex doesn't report the executable bit: on remote machines every file counts.
                        return entries.filter { !$0.isDirectory && ($0.isExecutable || !host.isLocal) }.map(\.name)
                    }
                }
                var all = Set<String>()
                for await names in group { all.formUnion(names) }
                return all
            }
            return found.sorted()
        }
        cache[host.id] = (path, task)
        return await task.value
    }
}

/// The PATH of the user's login shell on this Mac (apps get a minimal one from launchd).
enum LoginShell {
    static var executable: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static let pathTask = Task.detached(priority: .userInitiated) { () -> String in
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let out = Subprocess.run(executable, ["-l", "-c", "printf %s \"$PATH\""])
        guard let out, out.contains("/") else { return fallback }
        // Startup files may print before our output; PATH is the last line.
        return out.split(whereSeparator: \.isNewline).last.map(String.init) ?? fallback
    }

    static var path: String {
        get async { await pathTask.value }
    }
}

enum Subprocess {
    /// Run a program and return its standard output, or nil when it can't start or fails.
    /// Blocks: call it off the main thread.
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
                    environment: [String: String]? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let cwd, FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
