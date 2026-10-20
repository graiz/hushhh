import AppKit

// Draws the DMG window background: swift scripts/dmg-background.swift <out-dir>
// Writes background.png (660×400) and background@2x.png (1320×800). The app icon and
// the Applications link are placed by scripts/release.sh at (170, 205) and (490, 205).
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = CGSize(width: 660, height: 400)
let violet = NSColor(srgbRed: 0.42, green: 0.30, blue: 0.94, alpha: 1)

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Work in top-left coordinates, like Finder's icon positions.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // A quiet, light background with a hint of the brand colour.
    NSGradient(colors: [NSColor(srgbRed: 0.985, green: 0.98, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.94, green: 0.92, blue: 0.995, alpha: 1)])!
        .draw(in: CGRect(origin: .zero, size: size), angle: -90)

    func text(_ string: String, font: NSFont, color: NSColor, centerY: CGFloat) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = attributed.size().height
        ctx.saveGState()
        ctx.translateBy(x: 0, y: centerY + height / 2)
        ctx.scaleBy(x: 1, y: -1)
        attributed.draw(in: CGRect(x: 0, y: 0, width: size.width, height: height))
        ctx.restoreGState()
    }
    text("Drag Hushhh to your Applications folder", font: .systemFont(ofSize: 19, weight: .semibold),
         color: NSColor(white: 0.13, alpha: 1), centerY: 62)

    // Arrow from the app icon to the Applications folder.
    let y: CGFloat = 205
    let start = CGPoint(x: 252, y: y), end = CGPoint(x: 400, y: y)
    ctx.setStrokeColor(violet.cgColor)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.5, 11])
    ctx.move(to: start); ctx.addLine(to: CGPoint(x: end.x - 14, y: y)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setLineJoin(.round)
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: end.x - 16, y: y - 15))
    ctx.addLine(to: end)
    ctx.addLine(to: CGPoint(x: end.x - 16, y: y + 15))
    ctx.strokePath()

    text("Then open Hushhh and press Caps Lock to dictate.", font: .systemFont(ofSize: 13, weight: .regular),
         color: NSColor(white: 0.42, alpha: 1), centerY: 352)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: outDir + "/background.png")
render(scale: 2, to: outDir + "/background@2x.png")
print("wrote \(outDir)/background.png and background@2x.png")
