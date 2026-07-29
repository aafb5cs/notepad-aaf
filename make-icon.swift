#!/usr/bin/env swift
// Generates AppIcon.icns from Resources/aaf-logo.png.
//
// The source is a landscape image of the AAF mark (navy + gold letters) on a
// light checkerboard background (the "transparent" pattern is baked in as opaque
// pixels). App icons must be square, and simply padding the landscape image
// leaves a seam. Instead we key the letters off their light background — the
// background is bright and neutral (grey/white) while the letters are dark navy
// and chromatic gold — and composite just the letters onto a designed dark card.
//
// Usage:  swift make-icon.swift   ->  writes Resources/AppIcon.iconset/*
import AppKit
import Foundation

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let srcURL = cwd.appendingPathComponent("Resources/aaf-logo.png")

guard let srcImage = NSImage(contentsOf: srcURL) else {
    FileHandle.standardError.write("make-icon: cannot load \(srcURL.path)\n".data(using: .utf8)!)
    exit(1)
}
var srcRect = NSRect(origin: .zero, size: srcImage.size)
guard let srcCG = srcImage.cgImage(forProposedRect: &srcRect, context: nil, hints: nil) else {
    FileHandle.standardError.write("make-icon: cannot get CGImage\n".data(using: .utf8)!)
    exit(1)
}
let w = srcCG.width, h = srcCG.height

// Draw the source into a known deviceRGB buffer so we can read raw bytes without
// colorspace surprises (reading the PNG rep directly emits per-pixel warnings).
let spp = 4
let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * spp)
srcBuf.initialize(repeating: 0, count: w * h * spp)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bmp = CGContext(data: srcBuf, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * spp, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bmp.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
    let o = (y * w + x) * spp
    return (Double(srcBuf[o]) / 255, Double(srcBuf[o + 1]) / 255, Double(srcBuf[o + 2]) / 255)
}

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}

// Build a keyed logo: letters opaque, light checkerboard background transparent.
// A pixel is "background" when it is both bright and neutral (grey/white); the
// dark navy letters (low luminance) and the gold letters (high chroma) are kept.
// This also removes the baked-in drop shadow (mid-grey, neutral). Soft alpha ramp
// keeps edges clean.
let keyed = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let dst = keyed.bitmapData!
let dstRow = keyed.bytesPerRow
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let (cr, cg, cb) = px(x, y)
    let chroma = max(cr, cg, cb) - min(cr, cg, cb)
    let luma = 0.299 * cr + 0.587 * cg + 0.114 * cb
    let isLight = smoothstep(0.45, 0.62, luma)          // bright → background-ish
    let isNeutral = 1 - smoothstep(0.05, 0.12, chroma)  // greyish → background-ish
    let a = 1 - isLight * isNeutral                      // keep unless bright AND grey
    let o = y * dstRow + x * 4
    // NSBitmapImageRep is premultiplied by default, so scale RGB by alpha —
    // otherwise transparent light pixels render as visible white.
    dst[o] = UInt8(cr * a * 255); dst[o + 1] = UInt8(cg * a * 255); dst[o + 2] = UInt8(cb * a * 255)
    dst[o + 3] = UInt8(a * 255)
    if a > 0.5 { if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } }
}}
let keyedImage = NSImage(size: NSSize(width: w, height: h))
keyedImage.addRepresentation(keyed)
// Content rect in the image's (bottom-left origin) coordinate space.
let content = NSRect(x: minX, y: h - maxY, width: maxX - minX, height: maxY - minY)

// Render one square icon PNG at the given pixel size.
func renderPNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let canvas = CGFloat(size)

    // Dark card with a subtle top-to-bottom gradient (brand charcoal/navy).
    let top = NSColor(red: 0.145, green: 0.157, blue: 0.192, alpha: 1)
    let bot = NSColor(red: 0.078, green: 0.086, blue: 0.118, alpha: 1)
    let grad = NSGradient(colors: [top, bot])!
    grad.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)

    // Place the trimmed letters centred, filling ~82% of the canvas width.
    let targetW = canvas * 0.82
    let scale = min(targetW / content.width, (canvas * 0.62) / content.height)
    let dw = content.width * scale, dh = content.height * scale
    let dest = NSRect(x: (canvas - dw) / 2, y: (canvas - dh) / 2, width: dw, height: dh)

    // Soft drop shadow so the letters lift off the card.
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012),
                  blur: canvas * 0.02,
                  color: NSColor(white: 0, alpha: 0.45).cgColor)
    keyedImage.draw(in: dest, from: content, operation: .sourceOver, fraction: 1.0,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let iconset = cwd.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in variants {
    try! renderPNG(size: size).write(to: iconset.appendingPathComponent(name))
}
print("make-icon: keyed letters bbox \(Int(content.width))x\(Int(content.height)), wrote AppIcon.iconset")
