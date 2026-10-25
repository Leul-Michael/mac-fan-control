// Draws the app icon (a fan on a blue squircle) into an .iconset folder.
// usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = rect.insetBy(dx: s * 0.09, dy: s * 0.09)
        let shape = NSBezierPath(roundedRect: inset, xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.04, green: 0.22, blue: 0.62, alpha: 1))?.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let fan = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let f = fan.size
            fan.draw(in: NSRect(x: (s - f.width) / 2, y: (s - f.height) / 2, width: f.width, height: f.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
