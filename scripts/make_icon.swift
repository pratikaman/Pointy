// Renders the Pointy app icon: white cursor arrow + pizza on an indigo gradient.
// Usage: swift make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let side = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 4 * side, bitsPerPixel: 32
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let s = CGFloat(side)
let inset: CGFloat = s * 0.05
let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                      xRadius: s * 0.22, yRadius: s * 0.22)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.95, alpha: 1),
    ending: NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.55, alpha: 1)
)!
gradient.draw(in: bg, angle: -60)

// Classic mac arrow polygon (y-down coords), scaled and flipped into place.
let arrowPoints: [(CGFloat, CGFloat)] = [
    (0, 0), (0, 14.9), (4.1, 11.5), (6.7, 17.5), (9.6, 16.2), (7.0, 10.3), (12.4, 10.3),
]
let arrow = NSBezierPath()
let scale = s * 0.042
let ox = s * 0.24, oy = s * 0.78
for (i, p) in arrowPoints.enumerated() {
    let pt = NSPoint(x: ox + p.0 * scale, y: oy - p.1 * scale)
    if i == 0 { arrow.move(to: pt) } else { arrow.line(to: pt) }
}
arrow.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
shadow.shadowBlurRadius = s * 0.03
shadow.set()
NSColor.white.setFill()
arrow.fill()

let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.34)]
let pizza = "🍕" as NSString
let size = pizza.size(withAttributes: attrs)
pizza.draw(at: NSPoint(x: s * 0.72 - size.width / 2, y: s * 0.30 - size.height / 2), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
