import AppKit
import Observation
import RexKit
import TerminalKit

/// The command that is running now, from shell integration marks.
struct CommandRecord: Identifiable, Hashable {
    let id = UUID()
    var command: String
    var startedAt: Date
}

/// A finished command: its own native view in the block list.
struct CommandBlock: Identifiable, Hashable {
    let id: UUID
    var command: String
    var output: StyledText
    var exitCode: Int32?
    var duration: TimeInterval?
    /// Rebuilt from the terminal's contents after attaching (no exit code or timing).
    var restored = false

    var failed: Bool { (exitCode ?? 0) != 0 }
}

/// One Rex terminal block shown in a pane: its stream, engine, and blocks.
@MainActor
@Observable
final class PaneModel {
    enum Status: Equatable {
        case connecting
        case live
        case exited(Int)
        case failed(String)
    }

    enum ShellState: Equatable {
        case unknown   // no shell integration seen: classic terminal
        case prompt    // shell waits for a command: native prompt active
        case running   // a command runs: keys go to the terminal
    }

    /// How the pane is drawn.
    enum DisplayMode: Equatable {
        case blocks    // native block list + live block for the running command
        case terminal  // the whole grid: full-screen programs, or shells without integration
    }

    let sessionId: String
    let blockId: String

    private(set) var status: Status = .connecting
    private(set) var shellState: ShellState = .unknown
    private(set) var isAlternateScreen = false
    private(set) var title = ""
    private(set) var cwd = ""
    private(set) var gitBranch: String?
    private(set) var preamble = StyledText()
    private(set) var blocks: [CommandBlock] = []
    private(set) var running: CommandRecord?
    /// Rows the live block shows for the running command.
    private(set) var liveRows = 1
    var promptText = ""

    var usesNativePrompt: Bool { shellState != .unknown && !isAlternateScreen }
    var displayMode: DisplayMode { usesNativePrompt ? .blocks : .terminal }
    var runningCommand: CommandRecord? { running }
    var lastFinished: CommandBlock? { blocks.last }

    @ObservationIgnored let terminalView: TerminalView
    @ObservationIgnored private(set) var engine: TerminalEngine?
    @ObservationIgnored private(set) weak var server: ServerModel?
    @ObservationIgnored private var stream: RexTerminalStream?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: (Int, Int, Int, Int)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored weak var promptView: NSView?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    /// Horizontal space around output: list padding + card padding.
    static let outputInset: CGFloat = 26

    init(sessionId: String, blockId: String, server: ServerModel) {
        self.sessionId = sessionId
        self.blockId = blockId
        self.server = server
        terminalView = TerminalView()
        terminalView.terminalDelegate = self
        terminalView.sizesGridToBounds = false
        terminalView.rowWindowProvider = { [weak self] frame in self?.liveWindow(for: frame) }
        engine = try? TerminalEngine()
        wireEngine()
        terminalView.engine = engine
        configureTerminalView()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyTheme() }
        }
    }

    private var control: RexControl? { server?.control }

    // MARK: Connection

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        streamTask?.cancel()
        stream?.close()
    }

    private func run() async {
        guard let control else { return }
        do {
            try await control.own(sessionId: sessionId, blockIds: [blockId])
            applyTheme()
            if let (c, r, w, h) = pendingResize {
                try? await control.resize(sessionId: sessionId, blockId: blockId, columns: c, rows: r, cellWidth: w, cellHeight: h)
            }
            let ticket = try await control.dataTicket(sessionId: sessionId, blockId: blockId)
            let stream = try await RexTerminalStream.open(address: server?.address ?? .personal, ticket: ticket.ticket)
            self.stream = stream
            status = .live
            for try await event in stream.events {
                handle(event)
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { status = .failed(String(describing: error)) }
        }
        streamTask = nil
    }

    private func handle(_ event: RexStreamEvent) {
        guard let engine else { return }
        switch event {
        case .snapshot(let data):
            do {
                try engine.restore(snapshot: data)
                wireEngine()
                rebuildFromSnapshot()
            } catch {
                status = .failed(String(describing: error))
            }
        case .output(let data):
            engine.write(data)
            let alt = engine.isAlternateScreen
            if alt != isAlternateScreen {
                isAlternateScreen = alt
                configureTerminalView()
                updateFocus()
            }
        case .message(.resize(let c, let r, let w, let h, _)):
            engine.resize(columns: c, rows: r, cellWidth: w, cellHeight: h)
        case .message(.theme(let theme)):
            engine.setDefaultColors(
                foreground: theme.foreground.flatMap(RGB.init(hex:)),
                background: theme.background.flatMap(RGB.init(hex:)),
                cursor: theme.cursor.flatMap(RGB.init(hex:)),
                palette: Dictionary((theme.palette ?? []).compactMap { entry -> (Int, RGB)? in
                    let parts = entry.split(separator: "=")
                    guard parts.count == 2, let i = Int(parts[0]), let c = RGB(hex: String(parts[1])) else { return nil }
                    return (i, c)
                }, uniquingKeysWith: { $1 }))
        case .message(.childExited(let code)):
            status = .exited(code)
        case .message(.unknown):
            break
        }
        terminalView.refresh()
    }

    private func wireEngine() {
        engine?.onSemanticPrompt = { [weak self] event in self?.semantic(event) }
        engine?.onTitleChanged = { [weak self] t in self?.title = t }
        engine?.onBell = { NSSound.beep() }
        title = engine?.title ?? ""
    }

    /// After a snapshot: rebuild blocks from what's on screen and work out the shell's state.
    private func rebuildFromSnapshot() {
        guard let engine, let frame = engine.frame(force: true) else { return }
        isAlternateScreen = engine.isAlternateScreen
        let sawMarks = frame.rowSemantic.contains { $0 != 0 } || !engine.capturedHistory().commands.isEmpty
        if sawMarks {
            let (pre, commands) = engine.capturedHistory()
            preamble = pre
            blocks = commands.map { CommandBlock(id: UUID(), command: $0.command, output: $0.output, restored: true) }
            let cursorIndex = frame.cursor.y - frame.firstRow
            let atPrompt = cursorIndex >= 0 && cursorIndex < frame.rowSemantic.count && frame.rowSemantic[cursorIndex] != 0
            shellState = atPrompt ? .prompt : .running
            running = atPrompt ? nil : CommandRecord(command: "", startedAt: Date())
        }
        configureTerminalView()
        updateCwd()
        updateFocus()
        #if DEBUG
        // Restored panes don't take the autorun when only new sessions should.
        if shellState == .prompt, ProcessInfo.processInfo.environment["SWIFTTY_AUTORUN_NEW_ONLY"] == nil || blocks.isEmpty {
            DebugAutorun.next(for: self)
        }
        #endif
    }

    // MARK: Shell integration

    private func semantic(_ event: SemanticPromptEvent) {
        let wasUnknown = shellState == .unknown
        switch event {
        case .promptStart:
            shellState = .prompt
            running = nil
            updateCwd()
            #if DEBUG
            DebugAutorun.next(for: self)
            #endif
        case .inputStart:
            if shellState == .unknown { shellState = .prompt }
        case .outputStart(let command):
            running = CommandRecord(command: command, startedAt: Date())
            liveRows = 1
            shellState = .running
        case .commandEnd(let code):
            // The terminal holds the finished output right now: capture it as text.
            let output = engine?.captureFinishedOutput() ?? StyledText()
            let record = running
            let command = record?.command ?? ""
            if command == "clear" || command.hasPrefix("clear ") || command == "reset" {
                preamble = StyledText()
                blocks.removeAll()
            } else {
                blocks.append(CommandBlock(
                    id: record?.id ?? UUID(), command: command, output: output, exitCode: code,
                    duration: record.map { Date().timeIntervalSince($0.startedAt) }))
            }
            running = nil
        }
        if wasUnknown && shellState != .unknown { configureTerminalView() }
        updateFocus()
    }

    private func updateCwd() {
        guard let engine else { return }
        let raw = engine.pwd
        let path = URL(string: raw)?.path(percentEncoded: false) ?? raw
        guard !path.isEmpty, path != cwd else { return }
        cwd = path
        guard server?.isLocal == true else { gitBranch = nil; return }
        Task { [path] in
            let branch = await Git.currentBranch(in: path)
            if self.cwd == path { self.gitBranch = branch }
        }
    }

    // MARK: Terminal view

    /// The live block shows only the running command's rows; full-screen mode shows everything.
    private func configureTerminalView() {
        if displayMode == .blocks {
            terminalView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            terminalView.backgroundOverride = .clear
            terminalView.forwardsScrolling = true
        } else {
            terminalView.contentInsets = NSEdgeInsets(top: 10, left: Self.outputInset, bottom: 10, right: Self.outputInset)
            terminalView.backgroundOverride = .textBackgroundColor
            terminalView.forwardsScrolling = false
        }
        terminalView.showsCursor = shellState != .prompt || isAlternateScreen
        terminalView.refresh()
    }

    /// Viewport rows of the running command's output.
    private func liveWindow(for frame: TerminalFrame) -> Range<Int>? {
        guard displayMode == .blocks else { return nil }
        let cursorIndex = frame.cursor.y - frame.firstRow
        guard cursorIndex >= 0, cursorIndex < frame.rowSemantic.count else { return nil }
        // Output starts after the last prompt/command-line row above the cursor.
        var startIndex = frame.firstRow < 0 ? -frame.firstRow : 0
        var i = cursorIndex
        while i >= 0 {
            if frame.rowSemantic[i] != 0 { startIndex = i + 1; break }
            i -= 1
        }
        let start = startIndex + frame.firstRow
        var end = frame.cursor.y
        // Leave out a blank cursor row at the end, unless it's all there is.
        if end > start, frame.cells[cursorIndex].allSatisfy(\.isBlank) { end -= 1 }
        let count = max(1, end - start + 1)
        if count != liveRows {
            DispatchQueue.main.async { [weak self] in self?.liveRows = count }
        }
        return start..<(start + count)
    }

    /// Size the terminal grid from the pane's size.
    func layout(size: CGSize, promptHeight: CGFloat) {
        let cell = terminalView.cellSize
        guard cell.width > 0, cell.height > 0, size.width > 0 else { return }
        let cols = Int((size.width - Self.outputInset * 2) / cell.width)
        let reserve = usesNativePrompt ? promptHeight + 20 : 0
        let rows = Int((size.height - reserve - 20) / cell.height)
        terminalView.setGrid(columns: max(cols, 20), rows: max(rows, 5))
    }

    /// Put keyboard focus where typing should go.
    func updateFocus() {
        terminalView.showsCursor = !(shellState == .prompt && !isAlternateScreen)
        guard let window = terminalView.window ?? promptView?.window else { return }
        let responder = window.firstResponder
        let ownsFocus = responder === terminalView || (promptView != nil && responder === promptView)
        guard ownsFocus || responder === window else { return }
        focus()
    }

    func focus() {
        if usesNativePrompt && shellState == .prompt, let promptView, let window = promptView.window {
            window.makeFirstResponder(promptView)
        } else if let window = terminalView.window {
            window.makeFirstResponder(terminalView)
        }
    }

    // MARK: Commands

    /// Run the prompt's text in the shell.
    func submit(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let control else { return }
        server?.app?.history.add(command)
        promptText = ""
        terminalView.scrollToBottom()
        let sid = sessionId, bid = blockId
        Task {
            do {
                try await control.paste(sessionId: sid, blockId: bid, command)
                try await control.sendKey(sessionId: sid, blockId: bid, RexKeyEvent(
                    key: "enter", mods: "", consumedMods: "", text: "", unshiftedCodepoint: 13))
            } catch {
                NSLog("Swiftty: submit failed: \(error)")
            }
        }
    }

    /// Directory listing on the machine the shell runs on (for completion on remote servers).
    func listDir(_ path: String, prefix: String) async -> [(name: String, isDir: Bool)]? {
        guard let control else { return nil }
        guard let listing = try? await control.listDir(sessionId: sessionId, blockId: blockId, path: path, prefix: prefix),
              listing.status == nil || listing.status == "ok" else { return nil }
        server?.noteHome(listing.home)
        return (listing.entries ?? []).map { ($0.name, !($0.file ?? false)) }
    }

    /// Run a finished block's command again.
    func rerun(_ block: CommandBlock) {
        guard shellState == .prompt else { return }
        submit(block.command)
    }

    /// Send a control character to the shell (e.g. ⌃C from the prompt).
    func sendControl(_ letter: Character) {
        guard let control, let scalar = letter.unicodeScalars.first else { return }
        let sid = sessionId, bid = blockId
        Task {
            try? await control.sendKey(sessionId: sid, blockId: bid, RexKeyEvent(
                key: "key_\(letter)", mods: "ctrl", consumedMods: "", text: "", unshiftedCodepoint: Int(scalar.value)))
        }
    }

    /// ⌘K: remove the blocks and clear the terminal.
    func clearScreen() {
        preamble = StyledText()
        blocks.removeAll()
        guard let control else { return }
        let sid = sessionId, bid = blockId
        Task { _ = try? await control.blockMethod(sessionId: sid, blockId: bid, "clear") }
    }

    private func applyTheme() {
        guard let control else { return }
        let dark = NSApp.effectiveAppearance.isDark
        let sid = sessionId, bid = blockId
        Task { try? await control.setTheme(sessionId: sid, blockId: bid, TerminalTheme.rexTheme(dark: dark)) }
        terminalView.refresh()
    }
}

// MARK: - TerminalViewDelegate

extension PaneModel: TerminalViewDelegate {
    func terminalView(_ view: TerminalView, sendKey event: RexKeyEvent) {
        guard let control else { return }
        let sid = sessionId, bid = blockId
        Task { try? await control.sendKey(sessionId: sid, blockId: bid, event) }
    }

    func terminalView(_ view: TerminalView, paste text: String) {
        guard let control else { return }
        let sid = sessionId, bid = blockId
        Task { try? await control.paste(sessionId: sid, blockId: bid, text) }
    }

    func terminalView(_ view: TerminalView, didResizeTo columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        pendingResize = (columns, rows, cellWidth, cellHeight)
        guard status == .live || streamTask != nil, let control else { return }
        resizeTask?.cancel()
        let sid = sessionId, bid = blockId
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            try? await control.resize(sessionId: sid, blockId: bid, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        }
    }

    func terminalViewFocusChanged(_ view: TerminalView, focused: Bool) {
        guard let control else { return }
        let sid = sessionId, bid = blockId
        Task { try? await control.sendFocus(sessionId: sid, blockId: bid, focused: focused) }
    }
}

extension RGB {
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xff), g: UInt8(v >> 8 & 0xff), b: UInt8(v & 0xff))
    }
}

/// Small helpers that shell out to git.
enum Git {
    static func currentBranch(in directory: String) async -> String? {
        await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func branches(in directory: String) async -> [String] {
        let out = await run(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], in: directory) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    static func run(_ args: [String], in directory: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: directory)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

#if DEBUG
/// Debug aid: SWIFTTY_AUTORUN="cmd1;;cmd2" runs commands through the prompt's
/// submit path in the first pane that reaches a Swiftty prompt.
@MainActor
enum DebugAutorun {
    static var queue: [String]? = ProcessInfo.processInfo.environment["SWIFTTY_AUTORUN"]?
        .components(separatedBy: ";;").filter { !$0.isEmpty }
    static weak var owner: PaneModel?
    static var submittedAtBlockCount = -1

    static func next(for pane: PaneModel) {
        guard var q = queue, !q.isEmpty else { return }
        // SWIFTTY_AUTORUN_SESSION pins the commands to one session (by label).
        if let label = ProcessInfo.processInfo.environment["SWIFTTY_AUTORUN_SESSION"],
           pane.server?.sessions.first(where: { $0.sessionId == pane.sessionId })?.label != label { return }
        if owner == nil { owner = pane }
        guard owner === pane else { return }
        // One command at a time: wait until the previous one has finished.
        guard pane.blocks.count > submittedAtBlockCount else { return }
        submittedAtBlockCount = pane.blocks.count
        pane.terminalView.window?.makeKeyAndOrderFront(nil)
        let cmd = q.removeFirst()
        queue = q
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            pane.submit(cmd)
        }
    }
}
#endif
