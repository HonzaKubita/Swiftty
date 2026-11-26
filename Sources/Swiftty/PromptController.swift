import AppKit
import Observation

/// Drives one pane's prompt: completions, inline suggestions, history.
@MainActor
@Observable
final class PromptController: PromptTextViewDelegate {
    private(set) var items: [Completion] = []
    /// The highlighted completion. Nothing is highlighted until Tab (or ↓) picks one.
    var selection: Int?
    private(set) var isShowingCompletions = false
    private(set) var suggestion: String?
    /// Caret x position in the prompt view, for anchoring the completion list.
    private(set) var caretX: CGFloat = 0

    @ObservationIgnored weak var textView: PromptTextView?
    @ObservationIgnored private let pane: PaneModel
    @ObservationIgnored private let engine: CompletionEngine
    @ObservationIgnored private let history: CommandHistory
    @ObservationIgnored private var tokenRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var historyIndex: Int?
    /// Escape hides the list until the next edit.
    @ObservationIgnored private var dismissedByUser = false
    /// True while a completion is being inserted, so the edit doesn't start its own refresh.
    @ObservationIgnored private var applying = false

    init(pane: PaneModel, engine: CompletionEngine, history: CommandHistory) {
        self.pane = pane
        self.engine = engine
        self.history = history
    }

    // MARK: PromptTextViewDelegate

    func promptDidChange(_ view: PromptTextView) {
        pane.promptText = view.string
        historyIndex = nil
        suggestion = view.caretAtEnd ? history.suggestion(for: view.string).map { String($0.dropFirst(view.string.count)) } : nil
        guard !applying else { return }
        dismissedByUser = false
        // Arguments complete as you type (after "cd " the folders show up); the command
        // name itself only when the list is already open.
        let beforeCaret = (view.string as NSString).substring(to: min(view.caret, (view.string as NSString).length))
        if beforeCaret.contains(" ") || isShowingCompletions {
            refreshCompletions()
        } else {
            dismiss()
        }
    }

    func promptSubmit(_ view: PromptTextView) {
        let text = view.string
        dismiss()
        suggestion = nil
        view.resetHistoryBrowsing()
        historyIndex = nil
        view.text = ""
        pane.submit(text)
    }

    func promptCompletionKey(_ view: PromptTextView, _ key: PromptTextView.CompletionKey) -> Bool {
        switch key {
        case .tab:
            if isShowingCompletions, !items.isEmpty {
                selection = selection.map { ($0 + 1) % items.count } ?? 0
            } else {
                refreshCompletions(selectFirst: true)
            }
            return true
        case .backtab:
            guard isShowingCompletions, !items.isEmpty else { return true }
            selection = selection.map { ($0 - 1 + items.count) % items.count } ?? items.count - 1
            return true
        case .down:
            guard isShowingCompletions, !items.isEmpty else { return false }
            selection = selection.map { ($0 + 1) % items.count } ?? 0
            return true
        case .up:
            // With nothing picked, ↑ browses history as usual.
            guard isShowingCompletions, !items.isEmpty, let sel = selection else { return false }
            selection = sel == 0 ? nil : sel - 1
            return true
        case .accept:
            // Enter uses the picked completion; with nothing picked it runs the command.
            guard isShowingCompletions, let sel = selection, items.indices.contains(sel) else { return false }
            apply(items[sel])
            return true
        case .dismiss:
            guard isShowingCompletions else { return false }
            dismiss()
            dismissedByUser = true
            return true
        }
    }

    func promptHistory(_ view: PromptTextView, older: Bool) -> String? {
        let entries = history.entries
        guard !entries.isEmpty else { return nil }
        if older {
            let i = (historyIndex ?? entries.count) - 1
            guard i >= 0 else { return entries.first }
            historyIndex = i
            return entries[i]
        } else {
            guard let cur = historyIndex else { return nil }
            let i = cur + 1
            if i >= entries.count { historyIndex = nil; return nil }
            historyIndex = i
            return entries[i]
        }
    }

    func promptInterrupt(_ view: PromptTextView) {
        pane.sendControl("c")
    }

    func promptClearScreen(_ view: PromptTextView) {
        pane.clearScreen()
    }

    // MARK: Completions

    func refreshCompletions(selectFirst: Bool = false) {
        guard let view = textView, !dismissedByUser || selectFirst else { return }
        let text = view.string, caret = view.caret
        let isRemote = pane.server?.isLocal == false
        let cwd = pane.cwd.isEmpty ? (isRemote ? "~" : NSHomeDirectory()) : pane.cwd
        let pane = self.pane
        let lister: CompletionEngine.RemoteLister? = isRemote ? { dir, prefix in await pane.listDir(dir, prefix: prefix) } : nil
        completionTask?.cancel()
        completionTask = Task {
            let (ctx, results) = await engine.completions(text: text, caret: caret, cwd: cwd, remote: lister)
            guard !Task.isCancelled else { return }
            // The text moved on while we were listing: list again for what's there now,
            // rather than leaving the old list on screen.
            guard view.string == text, view.caret == caret else {
                refreshCompletions(selectFirst: selectFirst)
                return
            }
            tokenRange = ctx.range
            items = results
            selection = selectFirst && !results.isEmpty ? 0 : nil
            caretX = view.caretRect.minX
            isShowingCompletions = !results.isEmpty
        }
    }

    func apply(_ item: Completion) {
        // Nothing stays highlighted from the old list while the new one loads.
        selection = nil
        applying = true
        replaceToken(with: item.replacement)
        applying = false
        // Show what comes next (a folder's contents, a command's arguments), nothing picked.
        refreshCompletions()
    }

    private func replaceToken(with replacement: String) {
        guard let view = textView else { return }
        let length = (view.string as NSString).length
        let range = NSRange(location: min(tokenRange.location, length),
                            length: min(tokenRange.length, length - min(tokenRange.location, length)))
        if view.shouldChangeText(in: range, replacementString: replacement) {
            view.replaceCharacters(in: range, with: replacement)
            let end = range.location + (replacement as NSString).length
            view.setSelectedRange(NSRange(location: end, length: 0))
            view.didChangeText()
            tokenRange = NSRange(location: range.location, length: (replacement as NSString).length)
        }
    }

    func dismiss() {
        completionTask?.cancel()
        isShowingCompletions = false
        items = []
        selection = nil
    }

    static func commonPrefix(_ strings: [String]) -> String? {
        guard var prefix = strings.first else { return nil }
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { return nil }
        }
        return prefix
    }
}

#if DEBUG
extension PromptController {
    /// SWIFTTY_DEBUG_COMPLETE=1: type "cd projects/", Tab, Enter, logging the list after each step.
    func runDebugCompletionScript() {
        guard ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_COMPLETE"] != nil, let v = textView else { return }
        func log(_ step: String) {
            let names = items.prefix(4).map(\.display).joined(separator: ",")
            let line = "COMPLETE \(step): text=\(v.string) caret=\(v.caret) showing=\(isShowingCompletions) sel=\(selection.map(String.init) ?? "nil") items=[\(names)]\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        func key(_ code: UInt16, _ chars: String) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: v.window?.windowNumber ?? 0, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            v.keyDown(with: e)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            for ch in "cd projects/" {
                v.insertText(String(ch), replacementRange: v.selectedRange())
                try? await Task.sleep(for: .milliseconds(15))
            }
            log("typed")
            for _ in 0..<4 { key(0x30, "\t"); try? await Task.sleep(for: .milliseconds(20)) }
            log("tab x4")
            key(0x24, "\r")
            try? await Task.sleep(for: .milliseconds(150)); log("enter+150ms")
            try? await Task.sleep(for: .milliseconds(800)); log("enter+950ms")
            v.text = ""
        }
    }
}
#endif
