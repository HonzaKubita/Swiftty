import Foundation
import GhosttyVt

/// A step of a shell command, reported by OSC 133 shell integration.
public enum SemanticPromptEvent: Sendable, Equatable {
    case promptStart
    case inputStart
    case outputStart(command: String)
    case commandEnd(exitCode: Int32?)
}

public enum TerminalEngineError: Error, CustomStringConvertible {
    case ghostty(String, Int32)
    public var description: String {
        switch self {
        case .ghostty(let what, let code): "\(what) failed (libghostty-vt error \(code))"
        }
    }
}

/// One RGB color.
public struct RGB: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    init(_ c: GhosttyColorRgb) { r = c.r; g = c.g; b = c.b }
}

/// One cell of a frame, ready for the renderer.
public struct FrameCell: Sendable {
    public var codepoint: UInt32     // base codepoint; 0 for blank
    public var cluster: String?      // full grapheme cluster when it has more than one codepoint
    public var text: String {
        if let cluster { return cluster }
        return codepoint == 0 ? "" : String(Character(Unicode.Scalar(codepoint) ?? " "))
    }
    public var isBlank: Bool { cluster == nil && (codepoint == 0 || codepoint == 32) }
    public var fg: RGB
    public var bg: RGB?              // nil: default background
    public var flags: UInt16         // GhosttyStyleFlags (bold, italic, …)
    public var underline: UInt8
    public var wide: Bool
    public var selected: Bool
}

public struct FrameCursor: Sendable {
    public var x: Int, y: Int
    public var visible: Bool
    public var style: Int            // GhosttyCursorStyle
    public var color: RGB?
}

/// What the renderer draws: the viewport's rows of cells.
public struct TerminalFrame: Sendable {
    public var columns: Int
    /// Viewport rows (cells may hold extra overscan rows around them).
    public var rows: Int
    /// Viewport row of cells[0]: negative when overscan rows above the viewport are included.
    public var firstRow: Int
    public var cells: [[FrameCell]]
    public var background: RGB
    public var foreground: RGB
    public var cursor: FrameCursor
    public var dirtyRows: IndexSet
    public var fullRedraw: Bool
    /// Per viewport row: 0 none, 1 a prompt starts here, 2 prompt continuation.
    public var rowSemantic: [UInt8]
    /// Per viewport row: true if the row holds command input (what the user typed).
    public var rowHasInput: [Bool]
    /// Per row: its identity across updates.
    public var rowIds: [RowID]
    /// True when the viewport shows the newest output.
    public var atBottom: Bool
}

/// A row's identity that survives scrolling.
public struct RowID: Sendable, Hashable {
    public var a: UInt64, b: UInt64
}

public struct Scrollbar: Sendable, Equatable {
    public var total: Int
    public var offset: Int
    public var visible: Int
    public var isAtBottom: Bool { offset + visible >= total }
}

/// A libghostty-vt terminal: the local replica of a Rex terminal's state.
///
/// Rex's server runs the authoritative copy and answers the program's
/// queries; this replica only parses the same bytes and never writes back.
@MainActor
public final class TerminalEngine {
    public private(set) var columns: Int
    public private(set) var rows: Int

    public var onSemanticPrompt: ((SemanticPromptEvent) -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?

    private(set) var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var callbackBox: Unmanaged<CallbackBox>?

    /// Holds a weak reference back to the engine for C callbacks.
    final class CallbackBox {
        weak var engine: TerminalEngine?
        init(_ engine: TerminalEngine) { self.engine = engine }
    }

    public init(columns: Int = 80, rows: Int = 24) throws {
        self.columns = columns
        self.rows = rows
        var t: GhosttyTerminal?
        let r = ghostty_terminal_new(nil, &t, UInt16(columns), UInt16(rows))
        guard r == GHOSTTY_SUCCESS, let t else { throw TerminalEngineError.ghostty("terminal_new", r.rawValue) }
        terminal = t
        try setUpRenderState()
        installCallbacks()
    }

    isolated deinit {
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
        callbackBox?.release()
    }

    private func setUpRenderState() throws {
        var rs: GhosttyRenderState?
        var r = ghostty_render_state_new(nil, &rs)
        guard r == GHOSTTY_SUCCESS else { throw TerminalEngineError.ghostty("render_state_new", r.rawValue) }
        renderState = rs
        var it: GhosttyRenderStateRowIterator?
        r = ghostty_render_state_row_iterator_new(nil, &it)
        guard r == GHOSTTY_SUCCESS else { throw TerminalEngineError.ghostty("row_iterator_new", r.rawValue) }
        rowIterator = it
        var cells: GhosttyRenderStateRowCells?
        r = ghostty_render_state_row_cells_new(nil, &cells)
        guard r == GHOSTTY_SUCCESS else { throw TerminalEngineError.ghostty("row_cells_new", r.rawValue) }
        rowCells = cells
        // One extra row on each side, for smooth pixel scrolling.
        var overscan = GhosttyRenderStateOverscan(above: 1, below: 1)
        ghostty_render_state_set(rs, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, &overscan)
    }

    private func installCallbacks() {
        guard let terminal else { return }
        if callbackBox == nil { callbackBox = Unmanaged.passRetained(CallbackBox(self)) }
        let userdata = callbackBox!.toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)

        let semantic: GhosttyTerminalSemanticPromptFn = { _, userdata, event in
            guard let userdata, let event else { return }
            let box = Unmanaged<TerminalEngine.CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            let e = event.pointee
            let mapped: SemanticPromptEvent?
            switch e.kind {
            case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START:
                mapped = e.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY ? .promptStart : nil
            case GHOSTTY_SEMANTIC_PROMPT_INPUT_START: mapped = .inputStart
            case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START: mapped = .outputStart(command: e.command.string)
            case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END: mapped = .commandEnd(exitCode: e.has_exit_code ? e.exit_code : nil)
            default: mapped = nil
            }
            guard let mapped else { return }
            MainActor.assumeIsolated { box.engine?.onSemanticPrompt?(mapped) }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(semantic, to: UnsafeRawPointer.self))

        let title: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata, let terminal else { return }
            let box = Unmanaged<TerminalEngine.CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            var s = GhosttyString()
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s)
            let text = s.string
            MainActor.assumeIsolated { box.engine?.onTitleChanged?(text) }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))

        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            let box = Unmanaged<TerminalEngine.CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            MainActor.assumeIsolated { box.engine?.onBell?() }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    }

    // MARK: Input

    /// Replace all state with a GHOSTSNP snapshot from the stream.
    public func restore(snapshot: Data) throws {
        var restored: GhosttyTerminal?
        let result: GhosttyResult = snapshot.withUnsafeBytes { raw in
            var decoder: GhosttySnapshotDecoder?
            var r = ghostty_snapshot_decoder_new_buf(nil, &decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            guard r == GHOSTTY_SUCCESS, let decoder else { return r }
            defer { ghostty_snapshot_decoder_free(decoder) }
            var compress = true
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress)
            r = ghostty_snapshot_decoder_decode(decoder, &restored)
            return r
        }
        guard result == GHOSTTY_SUCCESS, let restored else {
            throw TerminalEngineError.ghostty("snapshot decode", result.rawValue)
        }
        if let terminal { ghostty_terminal_free(terminal) }
        terminal = restored
        columns = Int(value(GHOSTTY_TERMINAL_DATA_COLS, as: UInt16.self) ?? UInt16(columns))
        rows = Int(value(GHOSTTY_TERMINAL_DATA_ROWS, as: UInt16.self) ?? UInt16(rows))
        installCallbacks()
    }

    /// Feed live output from the stream.
    public func write(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            ghostty_terminal_vt_write(terminal, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    /// Match the size the server applied (from the stream's resize message).
    public func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard let terminal, columns > 0, rows > 0 else { return }
        self.columns = columns
        self.rows = rows
        ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), UInt32(max(cellWidth, 1)), UInt32(max(cellHeight, 1)))
    }

    /// Apply default colors from the stream's theme message.
    public func setDefaultColors(foreground: RGB?, background: RGB?, cursor: RGB?, palette: [Int: RGB]) {
        guard let terminal else { return }
        func set(_ opt: GhosttyTerminalOption, _ c: RGB?) {
            if var v = c.map({ GhosttyColorRgb(r: $0.r, g: $0.g, b: $0.b) }) {
                ghostty_terminal_set(terminal, opt, &v)
            } else {
                ghostty_terminal_set(terminal, opt, nil)
            }
        }
        set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, foreground)
        set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, background)
        set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, cursor)
        if !palette.isEmpty {
            var colors = TerminalEngine.defaultPalette
            for (i, c) in palette where (0..<256).contains(i) {
                colors[i] = GhosttyColorRgb(r: c.r, g: c.g, b: c.b)
            }
            colors.withUnsafeMutableBufferPointer { buf in
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buf.baseAddress)
            }
        }
    }

    /// The xterm 256-color palette, used as the base for partial palette changes.
    static let defaultPalette: [GhosttyColorRgb] = {
        var p: [GhosttyColorRgb] = []
        let base: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        for c in base { p.append(GhosttyColorRgb(r: c.0, g: c.1, b: c.2)) }
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { p.append(GhosttyColorRgb(r: r, g: g, b: b)) } } }
        for i in 0..<24 { let v = UInt8(8 + i * 10); p.append(GhosttyColorRgb(r: v, g: v, b: v)) }
        return p
    }()

    // MARK: State

    func value<T>(_ key: GhosttyTerminalData, as: T.Type) -> T? {
        guard let terminal else { return nil }
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        return ghostty_terminal_get(terminal, key, p) == GHOSTTY_SUCCESS ? p.pointee : nil
    }

    /// True while a full-screen program (vim, htop, less) uses the alternate screen.
    public var isAlternateScreen: Bool {
        value(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, as: GhosttyTerminalScreen.self) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    public var isMouseTracking: Bool { value(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, as: Bool.self) ?? false }

    public var title: String {
        guard let terminal else { return "" }
        var s = GhosttyString()
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS ? s.string : ""
    }

    public var pwd: String {
        guard let terminal else { return "" }
        var s = GhosttyString()
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS ? s.string : ""
    }

    public var scrollbar: Scrollbar {
        let s = value(GHOSTTY_TERMINAL_DATA_SCROLLBAR, as: GhosttyTerminalScrollbar.self)
        return Scrollbar(total: Int(s?.total ?? 0), offset: Int(s?.offset ?? 0), visible: Int(s?.len ?? 0))
    }

    /// Whether DEC private mode `value` is set (e.g. 2004 bracketed paste, 1 cursor keys).
    public func isModeSet(_ value: UInt16, ansi: Bool = false) -> Bool {
        guard let terminal else { return false }
        var q = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &q) == GHOSTTY_SUCCESS && q.value
    }

    // MARK: Viewport

    public func scroll(byRows delta: Int) {
        guard let terminal else { return }
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        v.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, v)
    }

    public func scrollToBottom() {
        guard let terminal else { return }
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, v)
    }

    public func scroll(toRow row: Int) {
        guard let terminal else { return }
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        v.value.row = max(0, row)
        ghostty_terminal_scroll_viewport(terminal, v)
    }

    public func scroll(byPrompts delta: Int) {
        guard let terminal else { return }
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT
        v.value.delta_prompt = delta
        ghostty_terminal_scroll_viewport(terminal, v)
    }

    // MARK: Rendering

    /// Pull the current viewport into a frame. Returns nil when nothing changed.
    public func frame(force: Bool = false) -> TerminalFrame? {
        guard let terminal, let renderState, let rowIterator, let rowCells else { return nil }
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return nil }

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE && !force { return nil }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let fgDefault = RGB(colors.foreground)
        let bgDefault = RGB(colors.background)

        var cur = GhosttyRenderStateCursor()
        cur.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur)

        var cols: UInt16 = 0, rowCount: UInt16 = 0
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)

        var it: GhosttyRenderStateRowIterator? = rowIterator
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)

        var cells: [[FrameCell]] = []
        cells.reserveCapacity(Int(rowCount))
        var dirtyRows = IndexSet()
        var rowSemantic: [UInt8] = []
        var rowHasInput: [Bool] = []
        var rowIds: [RowID] = []
        var y = 0
        var cellsHandle: GhosttyRenderStateRowCells? = rowCells
        var utf8 = [UInt8](repeating: 0, count: 64)
        while ghostty_render_state_row_iterator_next(rowIterator) {
            var rowDirty = false
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            if rowDirty || force || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL { dirtyRows.insert(y) }

            var sel = GhosttyRenderStateRowSelection()
            sel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let hasSel = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS

            var rawRow: GhosttyRow = 0
            var semantic = GHOSTTY_ROW_SEMANTIC_NONE
            if ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &rawRow) == GHOSTTY_SUCCESS {
                ghostty_row_get(rawRow, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic)
            }
            rowSemantic.append(UInt8(truncatingIfNeeded: semantic.rawValue))
            var rid = GhosttyRenderStateRowId()
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &rid)
            rowIds.append(RowID(a: rid.bits.0, b: rid.bits.1))
            var hasInput = false

            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle)
            var row: [FrameCell] = []
            row.reserveCapacity(Int(cols))
            var x = 0
            while ghostty_render_state_row_cells_next(rowCells) {
                var graphemes: UInt32 = 0
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemes)
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var codepoint: UInt32 = 0
                var cluster: String?
                if graphemes > 0 {
                    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
                    if graphemes > 1 {
                        var buf = GhosttyBuffer()
                        let n: Int = utf8.withUnsafeMutableBufferPointer { p in
                            buf.ptr = p.baseAddress
                            buf.cap = p.count
                            let r = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf)
                            return r == GHOSTTY_SUCCESS ? buf.len : 0
                        }
                        if n > 0 { cluster = String(decoding: utf8[0..<n], as: UTF8.self) }
                    }
                }
                let n = Int(graphemes)

                var style = GhosttyStyle()
                var hasStyling = false
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
                if hasStyling {
                    ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                }
                var fg = colors.foreground
                let fgSet = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
                var bg = colors.background
                let bgSet = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS

                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if !hasInput, n > 0 {
                    var sem = GHOSTTY_CELL_SEMANTIC_OUTPUT
                    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &sem)
                    hasInput = sem == GHOSTTY_CELL_SEMANTIC_INPUT
                }

                let selected = hasSel && x >= Int(sel.start_x) && x <= Int(sel.end_x)
                row.append(FrameCell(
                    codepoint: codepoint,
                    cluster: cluster,
                    fg: fgSet ? RGB(fg) : fgDefault,
                    bg: bgSet ? RGB(bg) : nil,
                    flags: style.flags,
                    underline: UInt8((style.flags >> 8) & 0x7),
                    wide: wide == GHOSTTY_CELL_WIDE_WIDE,
                    selected: selected))
                x += 1
            }
            cells.append(row)
            rowHasInput.append(hasInput)
            var clean = false
            ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY, &clean)
            y += 1
        }
        ghostty_render_state_clean(renderState)
        _ = it
        var overscan = GhosttyRenderStateOverscan(above: 0, below: 0)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &overscan)

        let cursor = FrameCursor(
            x: Int(cur.viewport_x), y: Int(cur.viewport_y),
            visible: cur.visible && cur.viewport_has_value,
            style: Int(cur.visual_style.rawValue),
            color: colors.cursor_has_value ? RGB(colors.cursor) : nil)
        return TerminalFrame(
            columns: Int(cols), rows: Int(rowCount), firstRow: -Int(overscan.above), cells: cells,
            background: bgDefault, foreground: fgDefault, cursor: cursor,
            dirtyRows: dirtyRows, fullRedraw: dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || force,
            rowSemantic: rowSemantic, rowHasInput: rowHasInput, rowIds: rowIds,
            atBottom: overscan.below == 0)
    }
}

extension GhosttyString {
    var string: String {
        guard let ptr, len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}
