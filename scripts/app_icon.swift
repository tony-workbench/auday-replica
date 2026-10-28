import AppKit
// App icon for the iPhone and watch apps (1024 px PNG): swift scripts/app_icon.swift out.png
// "Your day, kept": a 24-hour ring, the part captured so far in cream, a red dot where now is.
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func c(_ hex: Int) -> NSColor { NSColor(deviceRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
c(0x171614).setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
let cream = c(0xF3EEE4)
let center = NSPoint(x: 512, y: 512), r: CGFloat = 300
// the whole day: a faint 24-hour ring
let ring = NSBezierPath(); ring.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
ring.lineWidth = 64; c(0x34312C).setStroke(); ring.stroke()
// what has been kept so far: from midnight (top) clockwise to now
let kept = NSBezierPath(); kept.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: -150, clockwise: true)
kept.lineWidth = 64; kept.lineCapStyle = .round; cream.setStroke(); kept.stroke()
// now: the recording dot at the end of the kept arc
let a = CGFloat(-150) * .pi / 180
let p = NSPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
c(0x171614).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 96, y: p.y - 96, width: 192, height: 192)).fill()
c(0xE5483B).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 74, y: p.y - 74, width: 148, height: 148)).fill()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
