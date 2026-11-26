import AppKit
import MetalKit
import RexKit

/// What the terminal view asks its host to do.
@MainActor
public protocol TerminalViewDelegate: AnyObject {
    /// A key the user typed while the terminal itself has focus.
    func terminalView(_ view: TerminalView, sendKey event: RexKeyEvent)
    func terminalView(_ view: TerminalView, paste text: String)
    /// The grid that fits the view changed.
    func terminalView(_ view: TerminalView, didResizeTo columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    func terminalViewFocusChanged(_ view: TerminalView, focused: Bool)
}

/// A Metal view that draws a TerminalEngine and passes keys through to Rex.
@MainActor
public final class TerminalView: MTKView, MTKViewDelegate {
    public weak var terminalDelegate: TerminalViewDelegate?
    public var engine: TerminalEngine? { didSet { needsFullRedraw = true; setNeedsDisplay(bounds) } }

    /// Padding around the grid, in points.
    public var contentInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14) {
        didSet { relayoutGrid() }
    }

    /// Row backdrops for command blocks, in viewport rows.
    public var decorations: [RowDecoration] {
        get { renderer?.decorations ?? [] }
        set { renderer?.decorations = newValue; setNeedsDisplay(bounds) }
    }

    /// When false, the host decides the grid size (see `setGrid`) instead of the view's bounds.
    public var sizesGridToBounds = true

    /// When set, picks the viewport rows to draw for each frame (the live command block).
    public var rowWindowProvider: ((TerminalFrame) -> Range<Int>?)?

    /// Inside a scroll view: wheel events go to it instead of scrolling the terminal.
    public var forwardsScrolling = false

    /// Computes command-block backdrops for each frame that is drawn.
    public var decorationProvider: ((TerminalFrame) -> [RowDecoration])?

    /// Called after each frame is drawn (for overlays that track rows).
    public var onFrameDrawn: ((TerminalFrame) -> Void)?

    /// Hide the terminal cursor (while the native prompt has the input).
    public var showsCursor = true { didSet { if showsCursor != oldValue { needsFullRedraw = true; setNeedsDisplay(bounds) } } }

    /// Clear color behind the grid; nil draws the terminal's own background.
    public var backgroundOverride: NSColor? { didSet { setNeedsDisplay(bounds) } }

    public var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { rebuildRenderer() }
    }

    public private(set) var gridSize = (columns: 0, rows: 0)
    public var cellSize: CGSize { renderer?.atlas.metrics.pointSize ?? CGSize(width: 8, height: 16) }

    private var renderer: TerminalRenderer?
    private var needsFullRedraw = true
    private var lastFrame: TerminalFrame?
    private var markedText: NSMutableAttributedString?

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        delegate = self
        rebuildRenderer()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func rebuildRenderer() {
        guard let device else { return }
        renderer = TerminalRenderer(device: device, font: font, scale: scale)
        relayoutGrid()
        needsFullRedraw = true
        setNeedsDisplay(bounds)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildRenderer()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutGrid()
    }

    /// Size the grid explicitly (when `sizesGridToBounds` is false).
    public func setGrid(columns: Int, rows: Int) {
        guard let renderer, columns > 0, rows > 0, (columns, rows) != gridSize else { return }
        gridSize = (columns, rows)
        let m = renderer.atlas.metrics
        terminalDelegate?.terminalView(self, didResizeTo: columns, rows: rows, cellWidth: m.width, cellHeight: m.height)
    }

    private func relayoutGrid() {
        guard let renderer else { return }
        renderer.padding = SIMD2(Float(contentInsets.left * scale), Float(contentInsets.top * scale))
        guard sizesGridToBounds else { return }
        let m = renderer.atlas.metrics
        let s = scale
        renderer.padding = SIMD2(Float(contentInsets.left * s), Float(contentInsets.top * s))
        let usableW = bounds.width - contentInsets.left - contentInsets.right
        let usableH = bounds.height - contentInsets.top - contentInsets.bottom
        let cols = max(2, Int(usableW * s) / max(m.width, 1))
        let rows = max(1, Int(usableH * s) / max(m.height, 1))
        guard bounds.width > 0, bounds.height > 0, (cols, rows) != gridSize else { return }
        gridSize = (cols, rows)
        terminalDelegate?.terminalView(self, didResizeTo: cols, rows: rows, cellWidth: m.width, cellHeight: m.height)
    }

    /// Ask for a redraw after the engine changed.
    public func refresh() {
        setNeedsDisplay(bounds)
    }

    // MARK: Drawing

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsFullRedraw = true
    }

    public func draw(in view: MTKView) {
        guard let renderer, let engine else { return }
        if let f = engine.frame(force: needsFullRedraw) { lastFrame = f }
        needsFullRedraw = false
        guard var frame = lastFrame else { return }
        if !showsCursor { frame.cursor.visible = false }
        renderer.cursorFocused = window?.isKeyWindow == true && window?.firstResponder === self
        let bg = backgroundOverride?.usingColorSpace(.sRGB)
        let clear = bg.map { MTLClearColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: $0.alphaComponent) }
            ?? MTLClearColor(red: Double(frame.background.r) / 255, green: Double(frame.background.g) / 255,
                             blue: Double(frame.background.b) / 255, alpha: 1)
        renderer.drawsBackground = backgroundOverride == nil
        if let decorationProvider { renderer.decorations = decorationProvider(frame) }
        renderer.rowWindow = rowWindowProvider?(frame)
        renderer.draw(frame: frame, in: self, clear: clear)
        onFrameDrawn?(frame)
    }

    /// Point (in view coordinates, flipped) of a viewport row's top edge.
    public func yForRow(_ row: Int) -> CGFloat {
        contentInsets.top + (CGFloat(row) - scrollFraction) * cellSize.height
    }

    public override var isFlipped: Bool { true }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        needsFullRedraw = true
        setNeedsDisplay(bounds)
        terminalDelegate?.terminalViewFocusChanged(self, focused: true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        needsFullRedraw = true
        setNeedsDisplay(bounds)
        terminalDelegate?.terminalViewFocusChanged(self, focused: false)
        return true
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        if engine?.scrollbar.isAtBottom == false || scrollFraction != 0 { scrollToBottom() }
        terminalDelegate?.terminalView(self, sendKey: KeyMapping.event(event, action: event.isARepeat ? "repeat" : "press"))
    }

    public override func keyUp(with event: NSEvent) {
        terminalDelegate?.terminalView(self, sendKey: KeyMapping.event(event, action: "release"))
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        // Let ⌘ shortcuts reach the menu; send ctrl combos (⌃C, ⌃D…) to the program.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            terminalDelegate?.terminalView(self, paste: text)
        }
    }

    // MARK: Scrolling

    /// Sub-row part of the scroll position, in rows (0..<1).
    public private(set) var scrollFraction: CGFloat = 0
    /// Called when the scroll position changes (for overlays that follow rows).
    public var onScroll: (() -> Void)?
    private var altScrollRemainder: CGFloat = 0

    /// Jump to the newest output.
    public func scrollToBottom() {
        engine?.scrollToBottom()
        setScrollFraction(0)
        setNeedsDisplay(bounds)
    }

    private func setScrollFraction(_ f: CGFloat) {
        guard f != scrollFraction else { return }
        scrollFraction = f
        renderer?.scrollFraction = Float(f)
        onScroll?()
    }

    public override func scrollWheel(with event: NSEvent) {
        if forwardsScrolling && engine?.isAlternateScreen != true {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let rowHeight = max(cellSize.height, 1)
        let deltaRows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / rowHeight : event.scrollingDeltaY * 3
        scroll(byRows: deltaRows)
    }

    /// Scroll toward older output by `deltaRows` (fractions allowed).
    public func scroll(byRows deltaRows: CGFloat) {
        guard let engine else { return }

        if engine.isAlternateScreen {
            // Full-screen programs scroll with arrow keys, like most terminals do.
            altScrollRemainder += deltaRows
            let steps = Int(altScrollRemainder)
            guard steps != 0 else { return }
            altScrollRemainder -= CGFloat(steps)
            let key = steps > 0 ? "arrow_up" : "arrow_down"
            for _ in 0..<min(abs(steps), 20) {
                terminalDelegate?.terminalView(self, sendKey: RexKeyEvent(
                    key: key, mods: "", consumedMods: "", text: "", unshiftedCodepoint: 0))
            }
            return
        }

        let bar = engine.scrollbar
        let maxTop = CGFloat(max(0, bar.total - bar.visible))
        var pos = CGFloat(bar.offset) + scrollFraction - deltaRows
        pos = min(max(pos, 0), maxTop)
        let row = pos.rounded(.down)
        if Int(row) != bar.offset { engine.scroll(toRow: Int(row)) }
        setScrollFraction(pos - row)
        onScroll?()
        setNeedsDisplay(bounds)
    }
}
