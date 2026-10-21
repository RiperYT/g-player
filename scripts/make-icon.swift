// Draws the G-Player app icon and writes an .icns: swift scripts/make-icon.swift build/AppIcon.icns
// A graphite tile with a play mark, and the cartridge label strip from the library covers
// carrying three space colours.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.icns"

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // macOS icon grid: 824pt tile centred in 1024 with a continuous corner.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    NSShadow().then { $0.shadowColor = NSColor.black.withAlphaComponent(0.35); $0.shadowBlurRadius = 24 * s; $0.shadowOffset = NSSize(width: 0, height: -10 * s); $0.set() }
    NSColor(calibratedRed: 0.145, green: 0.157, blue: 0.180, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()
    path.addClip()
    // Soft top light.
    let light = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    light.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // Play mark, slightly rounded.
    let tri = NSBezierPath()
    let cx = tile.midX + 34 * s, cy = tile.midY + 70 * s, h = 300 * s
    tri.move(to: CGPoint(x: cx - h * 0.48, y: cy + h * 0.56))
    tri.line(to: CGPoint(x: cx + h * 0.62, y: cy))
    tri.line(to: CGPoint(x: cx - h * 0.48, y: cy - h * 0.56))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = 46 * s
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSColor(calibratedWhite: 0.97, alpha: 1).setStroke()
    tri.fill(); tri.stroke()

    // Cartridge label strip.
    let strip = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 150 * s)
    NSColor.black.withAlphaComponent(0.38).setFill()
    strip.fill()
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.373, 0.478, 0.353), (0.604, 0.420, 0.325), (0.357, 0.420, 0.498)]
    for (i, c) in colors.enumerated() {
        let d = 46 * s
        let r = CGRect(x: tile.minX + 92 * s + CGFloat(i) * 70 * s, y: strip.midY - d / 2, width: d, height: d)
        NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10 * s, yRadius: 10 * s).fill()
    }
    let bar = CGRect(x: tile.minX + 330 * s, y: strip.midY - 9 * s, width: 400 * s, height: 18 * s)
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 9 * s, yRadius: 9 * s).fill()
    image.unlockFocus()
    return image
}

extension NSShadow { func then(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self } }

let fm = FileManager.default
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = draw(size: px)
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        rep.size = NSSize(width: px, height: px)
        let png = rep.representation(using: .png, properties: [:])!
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print("icon: \(output)")
