import AppKit
import SwiftUI
import TerminalKit

/// A finished command's output: a read-only native text view, so selection,
/// copy, drag, Look Up, services and the find bar all work as in any Mac app.
struct OutputText: NSViewRepresentable {
    let text: StyledText
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> OutputTextView {
        let v = OutputTextView(usingTextLayoutManager: false)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.isRichText = true
        v.usesFindBar = true
        v.isIncrementalSearchingEnabled = true
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        return v
    }

    func updateNSView(_ v: OutputTextView, context: Context) {
        let dark = colorScheme == .dark
        if v.shown != text || v.shownDark != dark {
            v.shown = text
            v.shownDark = dark
            v.textStorage?.setAttributedString(OutputStyler.attributed(text, dark: dark))
            v.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: OutputTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        guard let lm = v.layoutManager, let tc = v.textContainer else { return nil }
        if tc.size.width != width { tc.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: width, height: ceil(h))
    }
}

final class OutputTextView: NSTextView {
    var shown: StyledText?
    var shownDark = false

    // Let the enclosing scroll view scroll; don't grab focus rings.
    override var focusRingType: NSFocusRingType { get { .none } set {} }
}

/// Turns styled terminal output into an attributed string for the current appearance.
@MainActor
enum OutputStyler {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

    static func attributed(_ text: StyledText, dark: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 2
        let palette = (dark ? TerminalTheme.darkPalette : TerminalTheme.lightPalette).compactMap(NSColor.init(hex:))
        for run in text.runs {
            let s = run.style
            var fg = color(s.fg, palette: palette) ?? .labelColor
            var bg = color(s.bg, palette: palette)
            if s.inverse {
                let oldFg = fg
                fg = bg ?? .textBackgroundColor
                bg = oldFg
            }
            if s.faint { fg = fg.withAlphaComponent(0.55) }
            var f = s.bold ? bold : font
            if s.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: s.invisible ? NSColor.clear : fg, .paragraphStyle: paragraph]
            if let bg { attrs[.backgroundColor] = bg }
            if s.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if s.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return out
    }

    static func color(_ c: TermColor, palette: [NSColor]) -> NSColor? {
        switch c {
        case .default:
            return nil
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .palette(let i):
            if Int(i) < palette.count { return palette[Int(i)] }
            if i >= 232 {
                let v = CGFloat(8 + Int(i - 232) * 10) / 255
                return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
            }
            let n = Int(i) - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[n / 36] / 255, green: steps[(n / 6) % 6] / 255, blue: steps[n % 6] / 255, alpha: 1)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
