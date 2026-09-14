import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.png"
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
NSGradient(colors: [NSColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1), NSColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1)])!.draw(in: background, angle: -90)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 46
shadow.shadowOffset = NSSize(width: 0, height: -28)
shadow.set()
let screen = NSBezierPath(roundedRect: NSRect(x: 195, y: 281, width: 634, height: 438), xRadius: 38, yRadius: 38)
NSGradient(colors: [NSColor(red: 0.57, green: 0.80, blue: 0.88, alpha: 1), NSColor(red: 0.60, green: 0.60, blue: 0.87, alpha: 1), NSColor(red: 0.83, green: 0.83, blue: 0.96, alpha: 1)])!.draw(in: screen, angle: -28)
NSGraphicsContext.restoreGraphicsState()

screen.lineWidth = 7
NSColor.white.withAlphaComponent(0.62).setStroke()
screen.stroke()
NSGraphicsContext.saveGraphicsState()
screen.addClip()
let arc = NSBezierPath(ovalIn: NSRect(x: 110, y: 315, width: 625, height: 790))
NSGradient(colors: [NSColor.white.withAlphaComponent(0.72), NSColor.white.withAlphaComponent(0)])!.draw(in: arc, angle: -38)
NSGraphicsContext.restoreGraphicsState()

let base = NSBezierPath()
base.move(to: NSPoint(x: 167, y: 247))
base.line(to: NSPoint(x: 858, y: 247))
base.curve(to: NSPoint(x: 813, y: 209), controlPoint1: NSPoint(x: 860, y: 220), controlPoint2: NSPoint(x: 837, y: 209))
base.line(to: NSPoint(x: 211, y: 209))
base.curve(to: NSPoint(x: 167, y: 247), controlPoint1: NSPoint(x: 187, y: 209), controlPoint2: NSPoint(x: 164, y: 220))
base.close()
NSGradient(colors: [NSColor(white: 0.86, alpha: 1), NSColor(white: 0.55, alpha: 1)])!.draw(in: base, angle: -90)
let indent = NSBezierPath(roundedRect: NSRect(x: 460, y: 235, width: 104, height: 12), xRadius: 5, yRadius: 5)
NSColor(white: 0.36, alpha: 1).setFill()
indent.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
