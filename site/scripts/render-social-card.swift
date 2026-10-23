#!/usr/bin/env swift
// Rebuild on macOS: swift site/scripts/render-social-card.swift
import AppKit

let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = NSSize(width: 1200, height: 630)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: size.height - y - h, width: w, height: h)
}

func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, ink: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let height = (value as NSString).size(withAttributes: attributes).height
    (value as NSString).draw(at: NSPoint(x: x, y: size.height - y - height), withAttributes: attributes)
}

let paper = color(0xf6f7f1)
let ink = color(0x183c30)
let green = color(0x2c7858)
let muted = color(0x65736a)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
paper.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

// Use the site's pale green, arched illustration field and existing app icon.
color(0xe8edde).setFill()
NSBezierPath(roundedRect: rect(815, 48, 337, 534), xRadius: 168, yRadius: 168).fill()
let orbit = NSBezierPath(ovalIn: rect(776, 148, 416, 328))
color(0xd0dcc5).setStroke()
orbit.lineWidth = 1.5
orbit.stroke()
let innerOrbit = NSBezierPath(ovalIn: rect(829, 100, 309, 424))
innerOrbit.lineWidth = 1.5
innerOrbit.stroke()
guard let icon = NSImage(contentsOf: site.appendingPathComponent("public/assets/coddle-icon.png")) else {
    fatalError("Missing existing Coddle icon")
}
icon.draw(in: rect(862, 180, 244, 244))

text("Coddle", x: 64, y: 51, font: .systemFont(ofSize: 40, weight: .semibold), ink: ink)
text("MACOS MENU BAR UTILITY", x: 66, y: 154, font: .systemFont(ofSize: 15, weight: .semibold), ink: green)
text("Charge with care", x: 60, y: 202,
     font: NSFont(name: "Georgia", size: 72)!, ink: ink)
text("Stay in flow", x: 60, y: 289,
     font: NSFont(name: "Georgia-Italic", size: 72)!, ink: green)
text("Charge limits · Smart charging · Stay awake", x: 66, y: 411,
     font: .systemFont(ofSize: 23, weight: .regular), ink: muted)
color(0xdce1d6).setFill()
NSBezierPath(rect: rect(66, 487, 674, 1)).fill()
text("Free & open source preview", x: 66, y: 523,
     font: .systemFont(ofSize: 19, weight: .medium), ink: ink)
text("coddle.kyun.si", x: 66, y: 558,
     font: .systemFont(ofSize: 19, weight: .regular), ink: muted)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode social card")
}
try data.write(to: site.appendingPathComponent("public/assets/social-card.png"))
print("Wrote Coddle social card: \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
