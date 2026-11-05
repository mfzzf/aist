// Renders the DMG window background: Resources/DMG/art.png (generated artwork, 3:2, no text)
// with the install hint drawn on top, at 1x and 2x for a 540×360-point window.
// Usage: swift scripts/dmg-background.swift <out-dir>  →  background.png, background@2x.png
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
guard let art = NSImage(contentsOf: root.appendingPathComponent("Resources/DMG/art.png")) else {
    fatalError("Resources/DMG/art.png missing")
}
let size = NSSize(width: 540, height: 360)

func render(scale: CGFloat, to name: String) throws {
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    art.draw(in: NSRect(origin: .zero, size: size))

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 1, alpha: 0.8)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = .zero
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let hint = NSAttributedString(string: "将 Aist 拖到「应用程序」即可完成安装", attributes: [
        .font: NSFont(name: "PingFangSC-Medium", size: 14) ?? .systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.56, alpha: 1),
        .shadow: shadow,
        .paragraphStyle: paragraph,
        .kern: 0.5,
    ])
    hint.draw(in: NSRect(x: 0, y: 62, width: size.width, height: 22))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

try render(scale: 1, to: "background.png")
try render(scale: 2, to: "background@2x.png")
