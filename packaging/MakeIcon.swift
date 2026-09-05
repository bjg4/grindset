import AppKit

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSColor(calibratedRed: 0.24, green: 0.19, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
        if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) {
            let rect = NSRect(x: CGFloat(pixels) * 0.18, y: CGFloat(pixels) * 0.24, width: CGFloat(pixels) * 0.64, height: CGFloat(pixels) * 0.54)
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            NSColor(calibratedRed: 0.96, green: 0.87, blue: 0.70, alpha: 1).setFill()
            NSRect(origin: .zero, size: symbol.size).fill()
            symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            tinted.draw(in: rect)
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(filename))
    }
}
