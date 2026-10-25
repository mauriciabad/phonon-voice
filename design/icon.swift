// Renders the app icon: Phonon's "Ph" mark from the xn-ptts README hero, rebuilt as a dot matrix.
// letters.json is that mark sampled on its dot grid (5.23 px pitch from (920, 304.5) in hero.webp).
//
//   swiftc -O icon.swift -o /tmp/icon && /tmp/icon letters.json icon-1024.png
//   for s in 16 32 128 256 512; do for k in 1 2; do sips -z $((s*k)) $((s*k)) icon-1024.png \
//     --out ../App/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@${k}x.png; done; done
import AppKit
let grid = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[Double]]
// Hero geometry, in hero pixels: letter dots every 5.23 from (920, 304.5); box dots every ~6.2 on 875...1124 × 234...484.
let letterPitch = 5.23, letterX = 920.0, letterY = 304.5
let box = (x0: 875.0, x1: 1124.0, y0: 234.0, y1: 484.0)
let size = 1024.0
let scale = 824.0 * 0.70 / (box.x1 - box.x0)
let cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2
func map(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: 512 + (x - cx) * scale, y: 512 - (y - cy) * scale) }

let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let path = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set(); NSColor.black.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.13, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))!.draw(in: path, angle: -90)

    let r = letterPitch * scale * 0.40
    for (j, row) in grid.prefix(23).enumerated() {
        for (i, v) in row.enumerated() where v > 0.5 {
            let p = map(letterX + Double(i) * letterPitch, letterY + Double(j) * letterPitch)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        }
    }
    let n = 40, rb = 6.2 * scale * 0.24
    NSColor(white: 1, alpha: 0.95).setFill()
    for k in 0...n {
        let t = Double(k) / Double(n)
        let xs = box.x0 + t * (box.x1 - box.x0), ys = box.y0 + t * (box.y1 - box.y0)
        for (x, y) in [(xs, box.y0), (xs, box.y1), (box.x0, ys), (box.x1, ys)] {
            let p = map(x, y)
            NSBezierPath(ovalIn: NSRect(x: p.x - rb, y: p.y - rb, width: 2 * rb, height: 2 * rb)).fill()
        }
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
