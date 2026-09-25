// Draw a scalable black-hole icon with AppKit; building requires no image tools beyond macOS.
import AppKit

// Use a fixed-size bitmap so iconutil receives exactly 1024 pixels regardless of display scale.
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("usage: make-icon <output.png>")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// A rounded midnight-blue tile gives the small menu-bar utility a recognizable Finder icon.
let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.025, green: 0.04, blue: 0.085, alpha: 1).setFill()
tile.fill()
tile.addClip()

// Layer broad translucent rings under a narrow warm ring to suggest gravitational lensing.
for width in stride(from: 100, through: 12, by: -8) {
    let ring = NSBezierPath(ovalIn: NSRect(x: 290, y: 290, width: 444, height: 444))
    ring.lineWidth = CGFloat(width)
    NSColor(calibratedRed: 1, green: 0.66, blue: 0.34, alpha: width == 12 ? 1 : 0.055).setStroke()
    ring.stroke()
}

// A tilted ellipse crosses the ring like the wallpaper's thin accretion disk.
NSGraphicsContext.saveGraphicsState()
let tilt = NSAffineTransform()
tilt.translateX(by: 512, yBy: 512)
tilt.rotate(byDegrees: -14)
tilt.concat()
let disk = NSBezierPath(ovalIn: NSRect(x: -365, y: -67, width: 730, height: 134))
disk.lineWidth = 18
NSColor(calibratedRed: 1, green: 0.82, blue: 0.58, alpha: 1).setStroke()
disk.stroke()
NSGraphicsContext.restoreGraphicsState()

// The small cyan point ties the icon to the project's pale-blue-dot theme.
NSColor(calibratedRed: 0.45, green: 0.83, blue: 1, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 215, y: 227, width: 15, height: 15)).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
