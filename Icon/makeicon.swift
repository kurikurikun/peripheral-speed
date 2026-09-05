import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Big Sur grid: 824x824 squircle centered on a 1024 canvas
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.01, green: 0.24, blue: 0.55, alpha: 1),
                    NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.20, alpha: 1)])!
    .draw(in: squircle, angle: -90)

// faint gauge arc behind the bolt
squircle.setClip()
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 450), radius: 285,
              startAngle: -25, endAngle: 205)
arc.lineWidth = 46
arc.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.16).setStroke()
arc.stroke()

// amber bolt
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = image.copy() as! NSImage
    img.lockFocus()
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .bold)
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let amber = tinted(bolt, NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.10, alpha: 1))
    let s = amber.size
    let scale = 560 / max(s.width, s.height)
    let w = s.width * scale, h = s.height * scale
    amber.draw(in: NSRect(x: 512 - w/2, y: 512 - h/2, width: w, height: h),
               from: .zero, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
