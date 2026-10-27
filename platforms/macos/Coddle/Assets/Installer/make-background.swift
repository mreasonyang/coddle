import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let width = 640.0, height = 400.0
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale,
                                 pixelsHigh: Int(height) * scale, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(srgbRed: 0.965, green: 0.969, blue: 0.945, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    func text(_ value: String, y: Double, size: Double, weight: NSFont.Weight, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (value as NSString).draw(in: NSRect(x: 30, y: y, width: width - 60, height: size * 1.7),
                                withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                 .foregroundColor: color, .paragraphStyle: style])
    }
    let ink = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.15, alpha: 1)
    let secondary = NSColor(srgbRed: 0.40, green: 0.42, blue: 0.37, alpha: 1)
    text("Install Coddle", y: 314, size: 29, weight: .semibold, color: ink)
    text("Drag Coddle into Applications", y: 282, size: 15, weight: .regular, color: secondary)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 280, y: 210))
    arrow.line(to: NSPoint(x: 360, y: 210))
    arrow.move(to: NSPoint(x: 346, y: 224))
    arrow.line(to: NSPoint(x: 360, y: 210))
    arrow.line(to: NSPoint(x: 346, y: 196))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(srgbRed: 0.40, green: 0.53, blue: 0.35, alpha: 1).setStroke()
    arrow.stroke()
    text("将 Coddle 拖入右侧“应用程序”文件夹", y: 80, size: 14, weight: .medium, color: ink)
    text("Then open Coddle from Applications", y: 49, size: 12, weight: .regular, color: secondary)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
