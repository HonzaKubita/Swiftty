// Renders Swiftty's app icon. Usage: swift scripts/make-icon.swift <out.png>
//
// A warm Swift-orange tile with one Liquid Glass shape on it: a prompt chevron
// whose two arms sweep back like a swift's wings.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1) // draw top-down

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

/// Rounded rect with continuous corners.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let rr = min(radius * 1.12, min(r.width, r.height) / 2)
    p.move(to: CGPoint(x: r.minX + rr, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + rr), control1: CGPoint(x: r.maxX - rr * 0.25, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + rr * 0.25))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
    p.addCurve(to: CGPoint(x: r.maxX - rr, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - rr * 0.25), control2: CGPoint(x: r.maxX - rr * 0.25, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - rr), control1: CGPoint(x: r.minX + rr * 0.25, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - rr * 0.25))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
    p.addCurve(to: CGPoint(x: r.minX + rr, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + rr * 0.25), control2: CGPoint(x: r.minX + rr * 0.25, y: r.minY))
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = squircle(body, radius: 185)

// MARK: Background: Swift's warm orange, lit from the top left.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 36, color: color(0x000000, 0.32))
ctx.addPath(tile)
ctx.setFillColor(color(0xF05138))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFB13B)), (0.5, color(0xFA7A35)), (1, color(0xE8402F))]),
                       start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: extend)
ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.28)), (1, color(0xFFFFFF, 0))]),
                       startCenter: CGPoint(x: 260, y: 220), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 220), endRadius: 620, options: [])
ctx.drawRadialGradient(gradient([(0, color(0x9E1A2A, 0.0)), (1, color(0x9E1A2A, 0.35))]),
                       startCenter: CGPoint(x: 512, y: 470), startRadius: 300,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 760, options: [])
ctx.restoreGState()

// Rim light around the tile edge.
ctx.saveGState()
ctx.addPath(tile)
ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.55)), (0.45, color(0xFFFFFF, 0.08)), (1, color(0xFFFFFF, 0.22))]),
                       start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: extend)
ctx.restoreGState()

// MARK: The glass chevron: one outline, two swept, tapering wings meeting at the point.
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: 250, y: 250))                                          // upper wing tip
chevron.addCurve(to: CGPoint(x: 776, y: 512), control1: CGPoint(x: 480, y: 285), control2: CGPoint(x: 680, y: 390))
chevron.addCurve(to: CGPoint(x: 250, y: 774), control1: CGPoint(x: 680, y: 634), control2: CGPoint(x: 480, y: 739))
chevron.addCurve(to: CGPoint(x: 600, y: 512), control1: CGPoint(x: 400, y: 690), control2: CGPoint(x: 540, y: 600))
chevron.addCurve(to: CGPoint(x: 250, y: 250), control1: CGPoint(x: 540, y: 424), control2: CGPoint(x: 400, y: 334))
chevron.closeSubpath()

// Shadow the glass casts on the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 44, color: color(0x7A1020, 0.45))
ctx.addPath(chevron)
ctx.setFillColor(color(0xFFFFFF, 0.35))
ctx.fillPath()
ctx.restoreGState()

// Glass body: bright, slightly frosted, tinted by the tile behind it.
ctx.saveGState()
ctx.addPath(chevron)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.96)), (0.5, color(0xFFF4EC, 0.80)), (1, color(0xFFD9C2, 0.70))]),
                       start: CGPoint(x: 0, y: 250), end: CGPoint(x: 0, y: 780), options: extend)
// Inner refraction: a soft orange band along the trailing edges.
ctx.drawRadialGradient(gradient([(0, color(0xFF8A3D, 0.0)), (0.75, color(0xFF8A3D, 0.0)), (1, color(0xFF7030, 0.35))]),
                       startCenter: CGPoint(x: 470, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 512), endRadius: 330, options: [])
// Specular highlight across the upper wing.
let spec = CGMutablePath()
spec.addEllipse(in: CGRect(x: 280, y: 236, width: 470, height: 190))
ctx.addPath(spec)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.9)), (1, color(0xFFFFFF, 0))]),
                       start: CGPoint(x: 0, y: 260), end: CGPoint(x: 0, y: 400), options: [])
ctx.restoreGState()

// Glass edge: bright on top, catching light, darker underneath.
ctx.saveGState()
ctx.addPath(chevron)
ctx.setLineWidth(5)
ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 1.0)), (0.5, color(0xFFFFFF, 0.55)), (1, color(0xFFE0CC, 0.85))]),
                       start: CGPoint(x: 0, y: 250), end: CGPoint(x: 0, y: 780), options: extend)
ctx.restoreGState()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
