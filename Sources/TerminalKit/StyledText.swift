import Foundation
import GhosttyVt

/// A color as a terminal program asked for it, resolved against a theme when drawn.
public enum TermColor: Sendable, Hashable {
    case `default`
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// Text attributes from SGR sequences.
public struct TermStyle: Sendable, Hashable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false
    public var invisible = false

    public init() {}
}

/// Terminal output as runs of styled text: what a finished command block shows.
public struct StyledText: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public var text: String
        public var style: TermStyle
    }

    public var runs: [Run]

    public init(runs: [Run] = []) { self.runs = runs }

    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { runs.allSatisfy { $0.text.allSatisfy(\.isWhitespace) } }

    /// Parse VT output (text, newlines and SGR) into styled runs. Other
    /// control sequences are skipped.
    public static func parse(vt: String) -> StyledText {
        var runs: [Run] = []
        var style = TermStyle()
        var current = ""
        let scalars = Array(vt.unicodeScalars)
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += current
            } else {
                runs.append(Run(text: current, style: style))
            }
            current = ""
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1b}", i + 1 < scalars.count {
                let next = scalars[i + 1]
                if next == "[" {
                    // CSI: parameters, then a final byte in 0x40...0x7E.
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    if j < scalars.count, scalars[j] == "m" {
                        flush()
                        applySGR(params, to: &style)
                    } else if j < scalars.count, scalars[j] == "C" {
                        // Cursor forward over empty cells: those are gaps between columns.
                        let n = max(1, Int(params) ?? 1)
                        flush()
                        let saved = style
                        style = TermStyle()
                        current = String(repeating: " ", count: min(n, 4096))
                        flush()
                        style = saved
                    }
                    i = j + 1
                    continue
                } else if next == "]" || next == "P" || next == "_" || next == "^" {
                    // OSC / DCS / APC / PM: skip to BEL or ST.
                    var j = i + 2
                    while j < scalars.count {
                        if scalars[j] == "\u{07}" { j += 1; break }
                        if scalars[j] == "\u{1b}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                        j += 1
                    }
                    i = j
                    continue
                } else {
                    i += 2
                    continue
                }
            }
            if c == "\r" { i += 1; continue }
            if c.value < 0x20 && c != "\n" && c != "\t" { i += 1; continue }
            current.unicodeScalars.append(c)
            i += 1
        }
        flush()
        // Drop trailing blank lines and spaces.
        while let last = runs.last, let ch = last.text.last, ch.isWhitespace {
            runs[runs.count - 1].text.removeLast()
            if runs[runs.count - 1].text.isEmpty { runs.removeLast() }
        }
        // And leading blank lines.
        while let first = runs.first, first.text.hasPrefix("\n") || first.text.isEmpty {
            if first.text.isEmpty { runs.removeFirst(); continue }
            runs[0].text.removeFirst()
        }
        return StyledText(runs: runs)
    }

    static func applySGR(_ params: String, to style: inout TermStyle) {
        let parts = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        var k = 0
        while k < parts.count {
            let p = parts[k]
            switch p {
            case 0: style = TermStyle()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 8: style.invisible = true
            case 9: style.strikethrough = true
            case 21, 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 28: style.invisible = false
            case 29: style.strikethrough = false
            case 30...37: style.fg = .palette(UInt8(p - 30))
            case 39: style.fg = .default
            case 40...47: style.bg = .palette(UInt8(p - 40))
            case 49: style.bg = .default
            case 90...97: style.fg = .palette(UInt8(p - 90 + 8))
            case 100...107: style.bg = .palette(UInt8(p - 100 + 8))
            case 38, 48, 58:
                var color: TermColor?
                if k + 2 < parts.count, parts[k + 1] == 5 {
                    color = .palette(UInt8(clamping: parts[k + 2]))
                    k += 2
                } else if k + 4 < parts.count, parts[k + 1] == 2 {
                    color = .rgb(UInt8(clamping: parts[k + 2]), UInt8(clamping: parts[k + 3]), UInt8(clamping: parts[k + 4]))
                    k += 4
                }
                if let color {
                    if p == 38 { style.fg = color } else if p == 48 { style.bg = color }
                }
            default: break
            }
            k += 1
        }
    }
}

/// A finished command recovered from the terminal's contents.
public struct CapturedCommand: Sendable {
    public var command: String
    public var output: StyledText
}

extension TerminalEngine {
    private func gridRef(tag: GhosttyPointTag, x: Int, y: Int) -> GhosttyGridRef? {
        guard let terminal else { return nil }
        var point = GhosttyPoint()
        point.tag = tag
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    /// Format a selection as VT (unwrapped, trimmed).
    private func format(_ selection: GhosttySelection?, vt: Bool) -> String? {
        guard let terminal else { return nil }
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS, let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var emit = vt ? GHOSTTY_FORMATTER_FORMAT_VT : GHOSTTY_FORMATTER_FORMAT_PLAIN
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        var yes = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
        var extras: GhosttyFormatterExtras = 0
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras)
        if var selection {
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)
        }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// The output of the command whose output contains the given screen point.
    private func outputSelection(screenRow y: Int) -> GhosttySelection? {
        guard let terminal, var ref = gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: 0, y: y) else { return nil }
        var sel = GhosttySelection()
        return ghostty_terminal_select_output(terminal, &ref, &sel) == GHOSTTY_SUCCESS ? sel : nil
    }

    private func rowSelection(screenRows rows: ClosedRange<Int>) -> GhosttySelection? {
        guard let start = gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: 0, y: rows.lowerBound),
              let end = gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: max(columns - 1, 0), y: rows.upperBound) else { return nil }
        var sel = GhosttySelection()
        sel.start = start
        sel.end = end
        return sel
    }

    private func semantic(screenRow y: Int) -> UInt8 {
        guard var ref = gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: 0, y: y) else { return 0 }
        var row: GhosttyRow = 0
        guard ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { return 0 }
        var s = GHOSTTY_ROW_SEMANTIC_NONE
        ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &s)
        return UInt8(truncatingIfNeeded: s.rawValue)
    }

    var totalRows: Int { Int(value(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, as: Int.self) ?? 0) }

    /// The cursor's row in screen coordinates (scrollback + active area).
    var cursorScreenRow: Int {
        let active = Int(value(GHOSTTY_TERMINAL_DATA_CURSOR_Y, as: UInt16.self) ?? 0)
        return max(0, totalRows - rows) + active
    }

    /// Output of the command that just finished (the cursor sits right after it).
    public func captureFinishedOutput() -> StyledText {
        let y = cursorScreenRow
        // The output ends on the cursor row (no trailing newline) or the row above it.
        for row in [y, y - 1] where row >= 0 {
            if let sel = outputSelection(screenRow: row), let vt = format(sel, vt: true) {
                return StyledText.parse(vt: vt)
            }
        }
        return StyledText()
    }

    /// Rebuild finished commands from everything on screen, e.g. after attaching.
    /// The last prompt (where the shell waits now, or the running command) is left out.
    public func capturedHistory() -> (preamble: StyledText, commands: [CapturedCommand]) {
        let total = totalRows
        guard total > 0 else { return (StyledText(), []) }
        var prompts: [Int] = []
        for y in 0..<total where semantic(screenRow: y) == 1 { prompts.append(y) }
        var preamble = StyledText()
        if let first = prompts.first, first > 0, let sel = rowSelection(screenRows: 0...(first - 1)),
           let vt = format(sel, vt: true) {
            preamble = StyledText.parse(vt: vt)
        } else if prompts.isEmpty, let vt = format(nil, vt: true) {
            preamble = StyledText.parse(vt: vt)
        }
        var commands: [CapturedCommand] = []
        for (i, p) in prompts.enumerated() where i < prompts.count - 1 {
            let next = prompts[i + 1]
            // The command line: the prompt row and any continuation rows.
            var last = p
            while last + 1 < next, semantic(screenRow: last + 1) == 2 { last += 1 }
            let command = rowSelection(screenRows: p...last).flatMap { format($0, vt: false) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var output = StyledText()
            if last + 1 < next, let sel = outputSelection(screenRow: last + 1), let vt = format(sel, vt: true) {
                output = StyledText.parse(vt: vt)
            }
            if command.isEmpty && output.isEmpty { continue }
            commands.append(CapturedCommand(command: command, output: output))
        }
        return (preamble, commands)
    }
}
