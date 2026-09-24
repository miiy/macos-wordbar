// Generate the WordBar icon: a blue rounded square with a white dictionary
// glyph, exported as a 1024x1024 PNG.
// Usage: swift gen_icon.swift output.png
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let bg = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
    xRadius: size * 0.22, yRadius: size * 0.22)
NSColor(calibratedRed: 0.19, green: 0.45, blue: 0.86, alpha: 1).setFill()
bg.fill()

if let sym = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil) {
    let conf = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let s = sym.withSymbolConfiguration(conf) {
        let ss = s.size
        s.draw(in: NSRect(x: (size - ss.width) / 2, y: (size - ss.height) / 2 - size * 0.01,
                          width: ss.width, height: ss.height),
               from: .zero, operation: .sourceOver, fraction: 1)
    }
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG export failed")
}
try png.write(to: URL(fileURLWithPath: out))
print("icon -> \(out)")
