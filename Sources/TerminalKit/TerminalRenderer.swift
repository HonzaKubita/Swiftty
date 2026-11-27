import AppKit
import Metal
import MetalKit
import simd

/// One quad: a solid rect, a monochrome glyph, or a color glyph.
struct Instance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
    var kind: UInt32          // 0 solid, 1 mono glyph, 2 color glyph, 3 rounded outline (width in uvSize.x)
    var radius: Float
}

/// A rounded backdrop the host wants behind a range of rows (command blocks).
public struct RowDecoration: Sendable, Equatable {
    public var firstRow: Int
    public var lastRow: Int
    public var fill: SIMD4<Float>
    public var stroke: SIMD4<Float>?
    /// A row drawn bold (the command line).
    public var headerRow: Int?
    /// Keep the card inside its rows at the top/bottom (a neighbour row has text).
    public var tightTop = false
    public var tightBottom = false
    public init(firstRow: Int, lastRow: Int, fill: SIMD4<Float>, stroke: SIMD4<Float>? = nil, headerRow: Int? = nil) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.fill = fill
        self.stroke = stroke
        self.headerRow = headerRow
    }
}

/// Draws a TerminalFrame with Metal: backgrounds, cursor, glyphs, decorations.
@MainActor
final class TerminalRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var atlas: GlyphAtlas
    private var atlasGeneration = 0

    /// Padding around the grid, in pixels.
    var padding = SIMD2<Float>(0, 0)
    var drawsBackground = true
    var cursorFocused = true
    var decorations: [RowDecoration] = []
    /// Sub-row scroll offset, in rows (0..<1): content moves up by this much.
    var scrollFraction: Float = 0
    /// Draw only these viewport rows, starting at the top (the live block).
    var rowWindow: Range<Int>?

    private var instanceBuffer: MTLBuffer?

    init?(device: MTLDevice, font: NSFont, scale: CGFloat) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Swiftty: Metal pipeline failed: \(error)")
            return nil
        }
        atlas = GlyphAtlas(device: device, font: font, scale: scale)
    }

    func setFont(_ font: NSFont, scale: CGFloat) {
        atlas = GlyphAtlas(device: device, font: font, scale: scale)
    }

    func draw(frame: TerminalFrame, in view: MTKView, clear: MTLClearColor) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].loadAction = .clear

        var instances = buildInstances(frame)
        // The glyph atlas filled up and started over while building: glyphs placed
        // before that point at stale texture regions, so build once more.
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            instances = buildInstances(frame)
            atlasGeneration = atlas.generation
        }
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !instances.isEmpty {
            let bytes = instances.count * MemoryLayout<Instance>.stride
            if instanceBuffer == nil || instanceBuffer!.length < bytes {
                instanceBuffer = device.makeBuffer(length: max(bytes, 1 << 16) * 2, options: .storageModeShared)
            }
            instances.withUnsafeBytes { raw in
                instanceBuffer!.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
            }
            var viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func color(_ c: RGB, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, alpha)
    }

    private func buildInstances(_ frame: TerminalFrame) -> [Instance] {
        let m = atlas.metrics
        let cw = Float(m.width), ch = Float(m.height)
        let tex = SIMD2<Float>(Float(atlas.textureSize.width), Float(atlas.textureSize.height))
        var bg: [Instance] = []
        var fg: [Instance] = []
        var lines: [Instance] = []
        bg.reserveCapacity(frame.rows * 4)
        fg.reserveCapacity(frame.columns * frame.rows / 2)

        let windowStart = rowWindow?.lowerBound ?? 0
        let shift = scrollFraction * ch + Float(windowStart) * ch
        func solid(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: SIMD4<Float>, radius: Float = 0) -> Instance {
            Instance(origin: SIMD2(x, y), size: SIMD2(w, h), uvOrigin: .zero, uvSize: .zero, color: c, kind: 0, radius: radius)
        }

        // Command block backdrops: rounded cards that reach half a row into the gap around them.
        var boldRows = Set<Int>()
        let radius = Float(9 * m.scale)
        for d in decorations where d.lastRow >= frame.firstRow && d.firstRow <= frame.rows {
            let first = max(d.firstRow, scrollFraction == 0 ? 0 : frame.firstRow)
            let last = min(d.lastRow, scrollFraction == 0 ? frame.rows - 1 : frame.rows)
            if first > last { continue }
            let loose = ch * 0.42, tight = Float(2 * m.scale)
            let top = d.tightTop ? tight : loose
            let bottom = d.tightBottom ? tight : loose
            let y = padding.y + Float(first) * ch - top - shift
            let h = Float(last - first + 1) * ch + top + bottom
            let x = padding.x - Float(8 * m.scale)
            let w = Float(frame.columns) * cw + Float(16 * m.scale)
            bg.append(solid(x, y, w, h, d.fill, radius: radius))
            if let stroke = d.stroke {
                var ring = solid(x, y, w, h, stroke, radius: radius)
                ring.kind = 3
                ring.uvSize = SIMD2(Float(1.5 * m.scale), 0)
                bg.append(ring)
            }
            if let hr = d.headerRow { boldRows.insert(hr) }
        }

        let defaultBg = frame.background
        for (index, row) in frame.cells.enumerated() {
            let y = index + frame.firstRow
            // Overscan rows only show while a scroll sits between two rows.
            if let w = rowWindow {
                if !w.contains(y) { continue }
            } else {
                if y < 0 && scrollFraction == 0 { continue }
                if y >= frame.rows && scrollFraction == 0 { continue }
            }
            let py = padding.y + Float(y) * ch - shift
            var x = 0
            while x < row.count {
                let cell = row[x]
                let px = padding.x + Float(x) * cw
                var fgc = cell.fg
                var bgc = cell.bg
                if cell.flags & (1 << 4) != 0 { // inverse
                    let oldFg = fgc
                    fgc = bgc ?? defaultBg
                    bgc = oldFg
                }
                let cells = cell.wide ? 2 : 1
                if cell.selected {
                    bg.append(solid(px, py, cw * Float(cells), ch, SIMD4(0.25, 0.45, 0.95, 0.45)))
                } else if let b = bgc, b != defaultBg || !drawsBackground {
                    bg.append(solid(px, py, cw * Float(cells), ch, color(b)))
                }

                let isCursorCell = frame.cursor.visible && frame.cursor.x == x && frame.cursor.y == y
                if isCursorCell, cursorFocused, frame.cursor.style == 1 { // block cursor: text in background color
                    fgc = defaultBg
                }

                if !cell.isBlank, cell.flags & (1 << 5) == 0 {
                    let key = GlyphAtlas.Key(codepoint: cell.codepoint, cluster: cell.cluster, bold: cell.flags & 1 != 0 || boldRows.contains(y), italic: cell.flags & 2 != 0, cells: cells)
                    let e = atlas.entry(for: key)
                    if !e.isEmpty {
                        let pad = Float(atlas.pad)
                        let alpha: Float = cell.flags & (1 << 2) != 0 ? 0.55 : 1
                        fg.append(Instance(
                            origin: SIMD2(px - pad, py - pad),
                            size: SIMD2(Float(e.rect.width), Float(e.rect.height)),
                            uvOrigin: SIMD2(Float(e.rect.minX), Float(e.rect.minY)) / tex,
                            uvSize: SIMD2(Float(e.rect.width), Float(e.rect.height)) / tex,
                            color: e.isColor ? SIMD4(1, 1, 1, alpha) : color(fgc, alpha: alpha),
                            kind: e.isColor ? 2 : 1, radius: 0))
                    }
                }
                if cell.underline != 0 {
                    let t = Float(m.underlineThickness)
                    lines.append(solid(px, py + ch - Float(m.descent) / 2 - t, cw * Float(cells), t, color(fgc)))
                }
                if cell.flags & (1 << 6) != 0 {
                    let t = Float(m.underlineThickness)
                    lines.append(solid(px, py + ch / 2, cw * Float(cells), t, color(fgc)))
                }
                x += cells
            }
        }

        // Cursor.
        let c = frame.cursor
        var cursorRects: [Instance] = []
        if c.visible, c.y < frame.rows, rowWindow?.contains(c.y) ?? true {
            let px = padding.x + Float(c.x) * cw
            let py = padding.y + Float(c.y) * ch - shift
            let cc = color(c.color ?? frame.foreground, alpha: 0.9)
            let thin = Float(max(2, m.scale * 1.5))
            if !cursorFocused {
                cursorRects += [solid(px, py, cw, thin, cc), solid(px, py + ch - thin, cw, thin, cc),
                                solid(px, py, thin, ch, cc), solid(px + cw - thin, py, thin, ch, cc)]
            } else {
                switch c.style {
                case 0: cursorRects.append(solid(px, py, thin, ch, cc))                 // bar
                case 2: cursorRects.append(solid(px, py + ch - thin, cw, thin, cc))     // underline
                case 3: cursorRects += [solid(px, py, cw, thin, cc), solid(px, py + ch - thin, cw, thin, cc),
                                        solid(px, py, thin, ch, cc), solid(px + cw - thin, py, thin, ch, cc)]
                default: cursorRects.append(solid(px, py, cw, ch, cc))                  // block
                }
            }
        }
        // Block cursors go under the text; thin cursors over it.
        if cursorFocused && c.style == 1 {
            return bg + cursorRects + fg + lines
        }
        return bg + fg + lines + cursorRects
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Instance { float2 origin; float2 size; float2 uvOrigin; float2 uvSize; float4 color; uint kind; float radius; };
    struct VOut { float4 position [[position]]; float2 uv; float4 color; uint kind [[flat]]; float2 local; float2 size; float radius; float strokeWidth; };
    vertex VOut vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Instance* inst [[buffer(0)]], constant float2& viewport [[buffer(1)]]) {
        Instance i = inst[iid];
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 p = i.origin + corner * i.size;
        VOut o;
        o.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
        o.uv = i.uvOrigin + corner * i.uvSize;
        o.color = i.color; o.kind = i.kind; o.local = corner * i.size; o.size = i.size; o.radius = i.radius; o.strokeWidth = i.uvSize.x;
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::nearest);
        if (in.kind == 0 || in.kind == 3) {
            float a = in.color.a;
            if (in.radius > 0.0) {
                float2 h = in.size * 0.5;
                float2 q = abs(in.local - h) - (h - in.radius);
                float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.radius;
                float cover = clamp(0.5 - d, 0.0, 1.0);
                if (in.kind == 3) cover -= clamp(0.5 - (d + in.strokeWidth), 0.0, 1.0);
                a *= cover;
            }
            return float4(in.color.rgb * a, a);
        }
        float4 t = atlas.sample(s, in.uv);
        if (in.kind == 1) { float a = t.a * in.color.a; return float4(in.color.rgb * a, a); }
        return t * in.color.a;
    }
    """
}
