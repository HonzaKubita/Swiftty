import AppKit
import CoreText
import Metal

/// Font metrics for the cell grid, in pixels.
public struct CellMetrics: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var ascent: CGFloat
    public var descent: CGFloat
    public var scale: CGFloat
    public var underlinePosition: CGFloat
    public var underlineThickness: CGFloat

    /// Size of one cell in points.
    public var pointSize: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
}

/// Rasterizes glyphs with Core Text into one RGBA texture.
///
/// Monochrome glyphs are stored as white coverage and tinted in the shader;
/// color glyphs (emoji) keep their colors.
@MainActor
final class GlyphAtlas {
    struct Key: Hashable {
        var codepoint: UInt32
        var cluster: String?
        var text: String { cluster ?? String(Character(Unicode.Scalar(codepoint) ?? " ")) }
        var bold: Bool
        var italic: Bool
        var cells: Int
    }

    struct Entry {
        var rect: CGRect      // pixels in the atlas
        var isColor: Bool
        var isEmpty: Bool
    }

    let device: MTLDevice
    private(set) var texture: MTLTexture
    private(set) var metrics: CellMetrics
    let pad: Int

    private var fonts: [Int: CTFont] = [:]   // 0 regular, 1 bold, 2 italic, 3 bold italic
    private var entries: [Key: Entry] = [:]
    private let size = 2048
    private var shelfX = 0, shelfY = 0, shelfH = 0
    private(set) var generation = 0

    init(device: MTLDevice, font: NSFont, scale: CGFloat) {
        self.device = device
        let base = CTFontCreateWithFontDescriptor(font.fontDescriptor as CTFontDescriptor, font.pointSize * scale, nil)
        fonts[0] = base
        fonts[1] = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) ?? base
        fonts[2] = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitItalic, .traitItalic) ?? base
        fonts[3] = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic]) ?? base

        var glyph = CGGlyph()
        var m: [UniChar] = [UniChar(UInt8(ascii: "M"))]
        CTFontGetGlyphsForCharacters(base, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base), descent = CTFontGetDescent(base), leading = CTFontGetLeading(base)
        let height = Int((ascent + descent + leading).rounded(.up)) + Int((2 * scale).rounded())
        metrics = CellMetrics(
            width: Int(advance.width.rounded(.up)), height: height,
            ascent: ascent, descent: descent, scale: scale,
            underlinePosition: CTFontGetUnderlinePosition(base),
            underlineThickness: max(CTFontGetUnderlineThickness(base), scale))
        pad = max(2, height / 3)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        texture = device.makeTexture(descriptor: desc)!
    }

    var textureSize: CGSize { CGSize(width: size, height: size) }

    func entry(for key: Key) -> Entry {
        if let e = entries[key] { return e }
        let e = rasterize(key)
        entries[key] = e
        return e
    }

    private func rasterize(_ key: Key) -> Entry {
        let font = fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]!
        let w = metrics.width * key.cells + pad * 2
        let h = metrics.height + pad * 2
        guard let slot = allocate(width: w, height: h) else {
            // Atlas full: start over. Callers re-request every frame, so this self-heals.
            entries.removeAll()
            shelfX = 0; shelfY = 0; shelfH = 0
            generation += 1
            return rasterize(key)
        }

        let attr = NSAttributedString(string: key.text, attributes: [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
            .ligature: 0,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var isColor = false
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                if let f = attrs[kCTFontAttributeName] {
                    let runFont = f as! CTFont
                    if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { isColor = true }
                }
            }
        }

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            // Scale wide glyphs (emoji) that overflow their cells down to fit.
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            let available = CGFloat(metrics.width * key.cells)
            let baseline = CGFloat(pad) + metrics.descent + CGFloat((metrics.height - Int((metrics.ascent + metrics.descent).rounded(.up))) / 2)
            if isColor, lineWidth > available, lineWidth > 0 {
                let s = available / lineWidth
                ctx.translateBy(x: CGFloat(pad), y: baseline)
                ctx.scaleBy(x: s, y: s)
                ctx.textPosition = .zero
            } else {
                ctx.textPosition = CGPoint(x: CGFloat(pad), y: baseline)
            }
            CTLineDraw(line, ctx)
            return true
        }
        let empty = !drew || !bytes.contains { $0 != 0 }
        if !empty {
            // A bitmap context's memory is already top row first, like the texture.
            bytes.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(Int(slot.minX), Int(slot.minY), w, h),
                                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
            }
        }
        return Entry(rect: slot, isColor: isColor, isEmpty: empty)
    }

    private func allocate(width: Int, height: Int) -> CGRect? {
        if shelfX + width > size {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        if shelfY + height > size { return nil }
        let r = CGRect(x: shelfX, y: shelfY, width: width, height: height)
        shelfX += width
        shelfH = max(shelfH, height)
        return r
    }
}
