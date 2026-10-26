#!/usr/bin/env swift
import AppKit
import Foundation

// Original geometric artwork for 手机视窗. No third-party image assets.
// Rebuild: xcrun swift scripts/generate-icon.swift [output-directory]
// Coordinates use a 1024-point canvas. Every icon size is rendered from paths.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : root.appendingPathComponent("Resources", isDirectory: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("likeweixin-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawArtwork() {
    let tile = rounded(NSRect(x: 80, y: 80, width: 864, height: 864), 196)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(8, 20, 58, 0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(28, 46, 121).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(24, 34, 87), ending: color(38, 115, 192))!
        .draw(in: tile, angle: 55)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(37, 208, 213, 0.5), ending: color(37, 208, 213, 0))!
        .draw(fromCenter: NSPoint(x: 850, y: 870), radius: 0,
              toCenter: NSPoint(x: 850, y: 870), radius: 780, options: [])
    NSGraphicsContext.restoreGraphicsState()
    let tileEdge = rounded(NSRect(x: 82, y: 82, width: 860, height: 860), 194)
    color(255, 255, 255, 0.15).setStroke()
    tileEdge.lineWidth = 3
    tileEdge.stroke()

    // A wide desktop window remains identifiable at small Dock/Finder sizes.
    let window = rounded(NSRect(x: 180, y: 294, width: 664, height: 438), 48)
    color(17, 35, 87, 0.28).setFill()
    window.fill()
    color(231, 246, 255, 0.9).setStroke()
    window.lineWidth = 20
    window.stroke()
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: 192, y: 654))
    divider.line(to: NSPoint(x: 832, y: 654))
    divider.lineWidth = 10
    color(231, 246, 255, 0.58).setStroke()
    divider.stroke()
    color(231, 246, 255, 0.8).setFill()
    for x: CGFloat in [221, 252, 283] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 680, width: 15, height: 15)).fill()
    }

    // The foreground portrait screen is the single main symbol, with generous
    // white borders and no tiny text, logos, chat bubbles or decorative controls.
    let phone = rounded(NSRect(x: 365, y: 198, width: 294, height: 628), 66)
    NSGraphicsContext.saveGraphicsState()
    let phoneShadow = NSShadow()
    phoneShadow.shadowColor = color(3, 18, 54, 0.45)
    phoneShadow.shadowBlurRadius = 26
    phoneShadow.shadowOffset = NSSize(width: 0, height: -12)
    phoneShadow.set()
    color(247, 253, 255).setFill()
    phone.fill()
    NSGraphicsContext.restoreGraphicsState()
    let screen = rounded(NSRect(x: 386, y: 220, width: 252, height: 584), 46)
    NSGradient(starting: color(15, 115, 188), ending: color(69, 221, 219))!
        .draw(in: screen, angle: 70)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: 386, y: 220))
    sheen.line(to: NSPoint(x: 386, y: 804))
    sheen.line(to: NSPoint(x: 600, y: 804))
    sheen.line(to: NSPoint(x: 460, y: 220))
    sheen.close()
    color(255, 255, 255, 0.1).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(247, 253, 255).setFill()
    rounded(NSRect(x: 462, y: 765, width: 100, height: 19), 9.5).fill()
    rounded(NSRect(x: 466, y: 240, width: 92, height: 10), 5).fill()
}

func render(pixels: Int, to destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: pixels * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not allocate icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.cgContext.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawArtwork()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try data.write(to: destination, options: .atomic)
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in sizes { try render(pixels: pixels, to: iconset.appendingPathComponent(name)) }
try render(pixels: 1024, to: output.appendingPathComponent("AppIcon.png"))
try render(pixels: 256, to: output.appendingPathComponent("AppIcon-preview.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created \(output.appendingPathComponent("AppIcon.png").path)")
print("Created \(output.appendingPathComponent("AppIcon.icns").path)")
print("Created \(output.appendingPathComponent("AppIcon-preview.png").path)")
