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
    @ObservationIgnored private let history: CommandHistory
    @ObservationIgnored private var tokenRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var historyIndex: Int?
    /// Escape hides the list until the next edit.
    @ObservationIgnored private var dismissedByUser = false
    /// True while a completion is being inserted, so the edit doesn't start its own refresh.
    @ObservationIgnored private var applying = false

    init(pane: PaneModel, history: CommandHistory) {
        self.pane = pane
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
        var shell = pane.shell
        if shell.cwd.isEmpty { shell.cwd = shell.home ?? (shell.isLocal ? NSHomeDirectory() : "~") }
        let host = pane.host
        let engine = PluginRegistry.shared.engine
        let recent = history.recentCommandNames()
        completionTask?.cancel()
        completionTask = Task {
            let result = await engine.completions(text: text, caret: caret, shell: shell, host: host,
                                                  recentCommands: recent)
            let results = result.items
            guard !Task.isCancelled else { return }
            // The text moved on while we were listing: list again for what's there now,
            // rather than leaving the old list on screen.
            guard view.string == text, view.caret == caret else {
                refreshCompletions(selectFirst: selectFirst)
                return
            }
            tokenRange = result.range
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

}

#if DEBUG
extension PromptController {
    /// SWIFTTY_DEBUG_COMPLETE="git switch ;;cd ~/": type each text into the prompt and log the
    /// completion list to stderr. Nothing is run. SWIFTTY_AUTORUN_SESSION pins it to one session.
    func runDebugCompletionScript() {
        let env = ProcessInfo.processInfo.environment
        guard let script = env["SWIFTTY_DEBUG_COMPLETE"], let v = textView else { return }
        if let label = env["SWIFTTY_AUTORUN_SESSION"],
           pane.server?.sessions.first(where: { $0.sessionId == pane.sessionId })?.label != label { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            for text in script.components(separatedBy: ";;") where !text.isEmpty {
                v.text = ""
                for ch in text {
                    v.insertText(String(ch), replacementRange: v.selectedRange())
                    try? await Task.sleep(for: .milliseconds(10))
                }
                try? await Task.sleep(for: .milliseconds(400))
                let names = items.prefix(8).map { $0.display + ($0.detail.map { " (\($0))" } ?? "") }.joined(separator: ", ")
                let line = "COMPLETE \"\(text)\" showing=\(isShowingCompletions) sel=\(selection.map(String.init) ?? "nil") items=[\(names)]\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            if env["SWIFTTY_DEBUG_COMPLETE_KEEP"] == nil {
                v.text = ""
                dismiss()
            }
        }
    }
}
#endif
