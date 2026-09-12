import AppKit
import Foundation

// Render the approved vector source; app icons never use a separate mascot drawing.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("web/mascot/first-frame.svg")
guard let cloud = NSImage(contentsOf: source) else { fatalError("Cannot read cloud SVG") }

for platform in ["macos", "ios"] {
    let directory = root.appendingPathComponent("\(platform)/App/Assets.xcassets/AppIcon.appiconset")
    let contents =
        try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Contents.json")))
        as! [String: Any]
    for image in contents["images"] as! [[String: String]] {
        guard let filename = image["filename"] else { continue }
        let points = Int(image["size"]?.split(separator: "x").first ?? "1024")!
        let scale = Int(image["scale"]?.dropLast() ?? "1")!
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(pixels)
        let inset = platform == "macos" ? side * 0.055 : 0
        let background = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 41 / 255, alpha: 1).setFill()
        let plate = NSBezierPath(
            roundedRect: background, xRadius: platform == "macos" ? side * 0.19 : 0,
            yRadius: platform == "macos" ? side * 0.19 : 0
        )
        plate.fill()
        plate.addClip()
        cloud.draw(in: NSRect(x: side * 0.01, y: side * 0.015, width: side * 0.98, height: side * 0.931))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
print("Rendered macOS and iOS icons from the shared cloud SVG.")
