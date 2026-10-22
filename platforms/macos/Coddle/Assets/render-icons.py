#!/usr/bin/env python3
"""Render SVGs with macOS AppKit. Requires only Python 3 and swiftc."""
from pathlib import Path
import subprocess
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
ICON_SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
# Compile stdin instead of creating a .swift file. The temporary executable and
# module cache live inside Assets and are removed even when rendering fails.
RENDERER = r'''
import AppKit
import Foundation

func render(_ source: String, _ output: String, _ pixels: Int) throws {
    guard let image = NSImage(contentsOfFile: source),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
              pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4,
              bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw NSError(domain: "CoddleIconRenderer", code: 1) }
    let size = NSSize(width: pixels, height: pixels)
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(origin: .zero, size: size)
    context.cgContext.clear(rect)
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
               respectFlipped: false, hints: nil)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    // Verify actual content, transparent corners, and black template RGB.
    var visible = 0
    for y in 0..<pixels {
        for x in 0..<pixels {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if color.alphaComponent > 0 {
                visible += 1
                if source.hasSuffix("MenuBarIcon.svg") {
                    guard color.redComponent == 0, color.greenComponent == 0,
                          color.blueComponent == 0 else {
                        throw NSError(domain: "TemplateMustBeBlack", code: 2)
                    }
                }
            }
        }
    }
    guard visible > 0, visible < pixels * pixels,
          bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0,
          let data = bitmap.representation(using: .png, properties: [:])
    else { throw NSError(domain: "InvalidIconRaster", code: 3) }
    try data.write(to: URL(fileURLWithPath: output), options: .atomic)
}
let args = CommandLine.arguments
for i in stride(from: 1, to: args.count, by: 3) {
    try render(args[i], args[i + 1], Int(args[i + 2])!)
}
'''


def main():
    iconset = ROOT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    # Never silently delete unrelated content from an existing directory.
    unexpected = {p.name for p in iconset.iterdir()} - ICON_SIZES.keys()
    if unexpected:
        raise SystemExit(f"Unexpected files in {iconset}: {sorted(unexpected)}")
    jobs = [(ASSETS / "AppIcon.svg", iconset / name, size)
            for name, size in ICON_SIZES.items()]
    jobs += [(ASSETS / "MenuBarIcon.svg", ASSETS / name, size)
             for name, size in [("MenuBarIconTemplate.png", 18),
                                ("MenuBarIconTemplate@2x.png", 36)]]
    with tempfile.TemporaryDirectory(prefix=".render-icons-", dir=ASSETS) as work:
        executable = Path(work) / "render-icons"
        subprocess.run(["swiftc", "-module-cache-path", str(Path(work) / "cache"),
                        "-module-name", "CoddleIconRenderer", "-",
                        "-o", str(executable), "-framework", "AppKit"],
                       input=RENDERER, text=True, check=True)
        subprocess.run([str(executable)] + [str(arg) for job in jobs for arg in job],
                       check=True)


def pack_icns():
    """Portable PNG-backed ICNS fallback when native iconutil rejects the set."""
    types = [b"icp4", b"ic11", b"icp5", b"ic12", b"ic07",
             b"ic13", b"ic08", b"ic14", b"ic09", b"ic10"]
    chunks = []
    for kind, name in zip(types, ICON_SIZES):
        data = (ROOT / "AppIcon.iconset" / name).read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"Invalid PNG: {name}")
        size = ICON_SIZES[name]
        if struct.unpack(">II", data[16:24]) != (size, size):
            raise SystemExit(f"Wrong PNG dimensions: {name}")
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    (ASSETS / "AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    if sys.argv[1:] == ["--pack-icns"]:
        pack_icns()
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit("Usage: render-icons.py [--pack-icns]")
