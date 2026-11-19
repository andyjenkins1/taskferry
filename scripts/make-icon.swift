// Draws the TaskFerry app icon as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>   (scripts/make-icon.sh turns it into AppIcon.icns)
import AppKit

let size = 1024
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(1)
}
let output = CommandLine.arguments[1]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon shape: a rounded square inset from the canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let plateShape = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
plateShape.addClip()

// Sky.
NSGradient(starting: rgb(0x2B6FE0), ending: rgb(0x7FD0F7))!.draw(in: plate, angle: 90)

/// A band of water whose top edge is a gentle wave.
func water(top: CGFloat, amplitude: CGFloat, phase: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: plate.minX, y: plate.minY))
    let steps = 120
    for i in 0...steps {
        let x = plate.minX + plate.width * CGFloat(i) / CGFloat(steps)
        let y = top + amplitude * sin(CGFloat(i) / CGFloat(steps) * .pi * 4 + phase)
        path.line(to: NSPoint(x: x, y: y))
    }
    path.line(to: NSPoint(x: plate.maxX, y: plate.minY))
    path.close()
    color.setFill()
    path.fill()
}

// Far water, behind the boat.
water(top: 420, amplitude: 14, phase: 0.6, color: rgb(0x1F58C4))

// The cargo: a ticked task.
let card = NSRect(x: 392, y: 520, width: 240, height: 240)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
rgb(0xFFFFFF).setFill()
NSBezierPath(roundedRect: card, xRadius: 52, yRadius: 52).fill()
NSGraphicsContext.restoreGraphicsState()

let tick = NSBezierPath()
tick.move(to: NSPoint(x: card.minX + 58, y: card.minY + 124))
tick.line(to: NSPoint(x: card.minX + 104, y: card.minY + 76))
tick.line(to: NSPoint(x: card.minX + 186, y: card.minY + 170))
tick.lineWidth = 36
tick.lineCapStyle = .round
tick.lineJoinStyle = .round
rgb(0x1FA85B).setStroke()
tick.stroke()

// The hull.
let hull = NSBezierPath()
hull.move(to: NSPoint(x: 232, y: 520))
hull.line(to: NSPoint(x: 792, y: 520))
hull.curve(to: NSPoint(x: 676, y: 352), controlPoint1: NSPoint(x: 780, y: 440), controlPoint2: NSPoint(x: 740, y: 352))
hull.line(to: NSPoint(x: 348, y: 352))
hull.curve(to: NSPoint(x: 232, y: 520), controlPoint1: NSPoint(x: 284, y: 352), controlPoint2: NSPoint(x: 244, y: 440))
hull.close()
rgb(0xFFFFFF).setFill()
hull.fill()

// A stripe along the hull.
NSGraphicsContext.saveGraphicsState()
hull.addClip()
rgb(0xF2643D).setFill()
NSRect(x: 200, y: 448, width: 640, height: 34).fill()
NSGraphicsContext.restoreGraphicsState()

// Near water, in front of the hull.
water(top: 372, amplitude: 16, phase: 2.4, color: rgb(0x3D8BEA))
water(top: 300, amplitude: 14, phase: 4.2, color: rgb(0x2E6FD6))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
