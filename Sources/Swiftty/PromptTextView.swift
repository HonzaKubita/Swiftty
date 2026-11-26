import AppKit
import SwiftUI

/// What the prompt text view reports to its owner.
@MainActor
protocol PromptTextViewDelegate: AnyObject {
    func promptDidChange(_ view: PromptTextView)
    func promptSubmit(_ view: PromptTextView)
    /// Return true if the key was handled by the completion list.
    func promptCompletionKey(_ view: PromptTextView, _ key: PromptTextView.CompletionKey) -> Bool
    func promptHistory(_ view: PromptTextView, older: Bool) -> String?
    func promptInterrupt(_ view: PromptTextView)
    func promptClearScreen(_ view: PromptTextView)
}

/// The native command prompt: a real NSTextView, so editing, selection,
/// undo, ⌥/⌘ navigation, services and input methods all work as on macOS.
final class PromptTextView: NSTextView {
    enum CompletionKey { case tab, backtab, up, down, accept, dismiss }

    weak var promptDelegate: PromptTextViewDelegate?

    /// Inline suggestion shown after the caret (from history).
    var suggestion: String? { didSet { if suggestion != oldValue { needsDisplay = true } } }

    /// History browsing state.
    private var historyDraft: String?

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    convenience init() {
        self.init(frame: .zero)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        font = Self.font
        textColor = .labelColor
        insertionPointColor = .controlAccentColor
        textContainerInset = NSSize(width: 0, height: 2)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        setAccessibilityLabel("Command")
    }

    var text: String {
        get { string }
        set {
            string = newValue
            setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            didChangeText()
        }
    }

    var caret: Int { selectedRange().location }
    var caretAtEnd: Bool { selectedRange().length == 0 && caret == (string as NSString).length }

    /// The caret's position in this view's coordinates.
    var caretRect: NSRect {
        let screen = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        guard let window, screen != .zero else { return .zero }
        return convert(window.convertFromScreen(screen), from: nil)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.numericPad, .function, .capsLock]).isEmpty
        switch event.keyCode {
        case 0x24, 0x4C: // return, enter
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if promptDelegate?.promptCompletionKey(self, .accept) == true { return }
            promptDelegate?.promptSubmit(self)
            return
        case 0x30 where plain: // tab
            if promptDelegate?.promptCompletionKey(self, .tab) == true { return }
            return
        case 0x30 where flags == .shift: // shift-tab
            _ = promptDelegate?.promptCompletionKey(self, .backtab)
            return
        case 0x35: // escape
            if promptDelegate?.promptCompletionKey(self, .dismiss) == true { return }
            if suggestion != nil { suggestion = nil; return }
            return
        case 0x7E where plain: // up
            if promptDelegate?.promptCompletionKey(self, .up) == true { return }
            if isOnFirstLine, let older = promptDelegate?.promptHistory(self, older: true) {
                if historyDraft == nil { historyDraft = string }
                text = older
                return
            }
        case 0x7D where plain: // down
            if promptDelegate?.promptCompletionKey(self, .down) == true { return }
            if isOnLastLine, historyDraft != nil {
                if let newer = promptDelegate?.promptHistory(self, older: false) {
                    text = newer
                } else {
                    text = historyDraft ?? ""
                    historyDraft = nil
                }
                return
            }
        case 0x7C where plain || flags == [.function]: // right arrow at the end accepts the suggestion
            if caretAtEnd, let s = suggestion, !s.isEmpty {
                insertText(s, replacementRange: selectedRange())
                suggestion = nil
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "c":
                if string.isEmpty { promptDelegate?.promptInterrupt(self) } else { text = "" }
                return true
            case "l":
                promptDelegate?.promptClearScreen(self)
                return true
            case "u":
                text = ""
                return true
            default:
                break
            }
        }
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            promptDelegate?.promptClearScreen(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var isOnFirstLine: Bool {
        !(string as NSString).substring(to: caret).contains("\n")
    }

    private var isOnLastLine: Bool {
        !(string as NSString).substring(from: caret).contains("\n")
    }

    override func didChangeText() {
        super.didChangeText()
        promptDelegate?.promptDidChange(self)
        invalidateIntrinsicContentSize()
    }

    func resetHistoryBrowsing() { historyDraft = nil }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let h = max(lm.usedRect(for: tc).height, Self.font.boundingRectForFont.height)
        return NSSize(width: NSView.noIntrinsicMetric, height: h + textContainerInset.height * 2)
    }

    // MARK: Inline suggestion

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let s = suggestion, !s.isEmpty, caretAtEnd, window?.firstResponder === self else { return }
        let r = caretRect
        guard r != .zero else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let shown = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        (shown as NSString).draw(at: NSPoint(x: r.minX + 1, y: r.minY), withAttributes: attrs)
    }
}

/// SwiftUI wrapper for the prompt.
struct PromptField: NSViewRepresentable {
    let pane: PaneModel
    @Bindable var controller: PromptController

    func makeNSView(context: Context) -> PromptTextView {
        let v = PromptTextView()
        v.promptDelegate = controller
        controller.textView = v
        pane.promptView = v
        v.text = pane.promptText
        DispatchQueue.main.async { pane.updateFocus() }
        #if DEBUG
        controller.runDebugCompletionScript()
        #endif
        return v
    }

    func updateNSView(_ v: PromptTextView, context: Context) {
        v.promptDelegate = controller
        v.suggestion = controller.suggestion
        if v.string != pane.promptText { v.text = pane.promptText }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PromptTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        nsView.frame.size.width = width
        return CGSize(width: width, height: min(nsView.intrinsicContentSize.height, 160))
    }
}
