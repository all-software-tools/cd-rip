import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale, size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.06
    NSColor(red: 0.055, green: 0.067, blue: 0.073, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size-2*inset, height: size-2*inset), xRadius: size*0.185, yRadius: size*0.185).fill()
    let green = NSColor(red: 0.64, green: 0.90, blue: 0.38, alpha: 1)
    let symbol = NSImage(systemSymbolName: "opticaldisc.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size*0.68, weight: .regular).applying(.init(paletteColors: [green])))!
    let side = size*0.68
    symbol.draw(in: NSRect(x: (size-side)/2, y: (size-side)/2, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(filename))
}
