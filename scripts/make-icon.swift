// Draws the G-Player app icon and writes an .icns: swift scripts/make-icon.swift build/AppIcon.icns
// A play mark with a gradient and the letter G cut into it, on a dark tile. The artwork is scripts/app-icon.svg
// (a 1024 canvas); this script draws the same shapes into the macOS icon grid, so building needs no SVG tools.
// With --png <file> it writes one 1024 px PNG instead.
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let pngOutput = args.firstIndex(of: "--png").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let output = args.first { !$0.hasPrefix("--") && $0 != pngOutput } ?? "build/AppIcon.icns"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Fills the current clip with a linear gradient from the top left to the bottom right of `box`, as SVG's
/// objectBoundingBox gradients do (x1=0 y1=0 x2=1 y2=1, stretched with the box).
func fillDiagonal(_ ctx: CGContext, _ box: CGRect, _ stops: [(CGFloat, UInt32)]) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.1) } as CFArray,
                              locations: stops.map(\.0))!
    ctx.saveGState()
    ctx.translateBy(x: box.minX, y: box.minY)
    ctx.scaleBy(x: box.width, y: box.height)
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1, y: 1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Draws the icon `size` pixels wide (a bitmap of its own: NSImage.lockFocus would draw twice as many on a Retina screen).
func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = size / 1024
    // macOS icon grid: 824pt tile centred in 1024 with a continuous corner, and a soft shadow under it.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x080B12)); ctx.fillPath()
    ctx.restoreGState()

    // From here on, the SVG's coordinates: its 1024 canvas is the tile, y going down.
    ctx.addPath(tilePath); ctx.clip()
    ctx.translateBy(x: tile.minX, y: tile.maxY)
    ctx.scaleBy(x: tile.width / 1024, y: -tile.height / 1024)
    fillDiagonal(ctx, CGRect(x: 0, y: 0, width: 1024, height: 1024), [(0, 0x151927), (1, 0x080B12)])

    // Play mark: M292 190 Q260 173 260 221 L260 803 Q260 851 301 827 L800 543 Q847 516 800 489 Z
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 292, y: 190))
    play.addQuadCurve(to: CGPoint(x: 260, y: 221), control: CGPoint(x: 260, y: 173))
    play.addLine(to: CGPoint(x: 260, y: 803))
    play.addQuadCurve(to: CGPoint(x: 301, y: 827), control: CGPoint(x: 260, y: 851))
    play.addLine(to: CGPoint(x: 800, y: 543))
    play.addQuadCurve(to: CGPoint(x: 800, y: 489), control: CGPoint(x: 847, y: 516))
    play.closeSubpath()
    ctx.saveGState()
    ctx.addPath(play); ctx.clip()
    fillDiagonal(ctx, play.boundingBoxOfPath, [(0, 0x66C9FF), (0.52, 0x6B7DFF), (1, 0xAE6DFF)])
    ctx.restoreGState()

    // The G, in the tile's dark colour: M580 375 A170 170 0 1 0 588 622 L588 525 L466 525, stroke 76.
    let start = CGPoint(x: 580, y: 375), end = CGPoint(x: 588, y: 622), r: CGFloat = 170
    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    let chord = hypot(end.x - start.x, end.y - start.y)
    let h = (r * r - chord * chord / 4).squareRoot()
    // Of the two circles through both points, the large arc swept towards decreasing angles (sweep-flag 0) goes
    // around the one towards the tile's left.
    let centre = CGPoint(x: mid.x - h * (end.y - start.y) / chord, y: mid.y + h * (end.x - start.x) / chord)
    let g = CGMutablePath()
    g.move(to: start)
    g.addArc(center: centre, radius: r, startAngle: atan2(start.y - centre.y, start.x - centre.x),
             endAngle: atan2(end.y - centre.y, end.x - centre.x), clockwise: true)
    g.addLine(to: CGPoint(x: 588, y: 525))
    g.addLine(to: CGPoint(x: 466, y: 525))
    ctx.addPath(g)
    ctx.setStrokeColor(rgb(0x111525)); ctx.setLineWidth(76); ctx.setLineCap(.square); ctx.setLineJoin(.round)
    ctx.strokePath()
    return rep
}

func png(_ px: CGFloat) -> Data { draw(size: px).representation(using: .png, properties: [:])! }

if let pngOutput {
    try! png(1024).write(to: URL(fileURLWithPath: pngOutput))
    print("icon: \(pngOutput)")
    exit(0)
}
let fm = FileManager.default
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(CGFloat(base * scale)).write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
guard p.terminationStatus == 0, fm.fileExists(atPath: output) else {
    FileHandle.standardError.write(Data("iconutil failed (status \(p.terminationStatus)): no icon was made\n".utf8))
    exit(1)
}
print("icon: \(output)")
