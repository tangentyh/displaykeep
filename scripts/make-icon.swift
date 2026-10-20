#!/usr/bin/env swift
//
// make-icon.swift — draw DisplayKeep's app icon and write an .iconset for iconutil.
//
// The icon is generated instead of checked in: it is three shapes (a display, a stand and a
// sun), so a script that redraws it at every size stays small and diffable, and the repo keeps
// no binary art. `make build` runs this and then iconutil; `make icon` redraws, rebuilds and
// re-signs the bundle.
//
// usage: swift scripts/make-icon.swift <output.iconset>

import AppKit

// Every coordinate below is in this space; each bitmap is just scaled down from it, so the
// 16pt icon is the same drawing as the 1024px one rather than a redrawn approximation.
let canvas: CGFloat = 1024

// The sizes iconutil insists on for a macOS .icns.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func gradient(_ stops: [CGColor], at locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// macOS 11+ icons are squircle-shaped, not rounded rectangles: a rounded rect has a visible
// seam where the straight edge meets the corner. A superellipse, |x/a|^n + |y/b|^n = 1, is the
// same idea with continuous curvature; n = 5 is the usual stand-in for Apple's curve.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func draw(into cg: CGContext, simplified: Bool) {
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // --- the plate -------------------------------------------------------
    // 824x824 inside a 1024 canvas is Apple's macOS app-icon grid.
    let plate = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    cg.saveGState()
    cg.addPath(plate)
    cg.clip()
    cg.drawLinearGradient(
        gradient([rgb(96, 110, 255), rgb(76, 62, 214)], at: [0, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A soft highlight in the upper third so the gradient does not read as flat at 512px.
    cg.drawRadialGradient(
        gradient([rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0)], at: [0, 1]),
        startCenter: CGPoint(x: 400, y: 850), startRadius: 0,
        endCenter: CGPoint(x: 400, y: 850), endRadius: 560, options: [])
    cg.restoreGState()

    // --- the display -----------------------------------------------------
    // Screen, neck and foot are filled white as one group so the drop shadow is cast by the
    // silhouette rather than by each shape (which would darken the joins).
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 34,
                 color: rgb(18, 12, 60, 0.35))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    let screen = CGRect(x: 236, y: 356, width: 552, height: 392)
    cg.setFillColor(rgb(255, 255, 255, 0.97))
    cg.addPath(rounded(screen, 46))
    cg.fillPath()

    cg.addPath(rounded(CGRect(x: 486, y: 300, width: 52, height: 64), 12))
    cg.fillPath()
    cg.addPath(rounded(CGRect(x: 400, y: 276, width: 224, height: 44), 22))
    cg.fillPath()

    cg.endTransparencyLayer()
    cg.restoreGState()

    // Glass: near-black indigo, so the display reads as a powered screen against the plate
    // rather than as a hole cut in it, and the warm sun has something to sit on.
    cg.saveGState()
    cg.addPath(rounded(screen.insetBy(dx: 15, dy: 15), 32))
    cg.clip()
    cg.drawLinearGradient(
        gradient([rgb(45, 42, 112), rgb(20, 18, 56)], at: [0, 1]),
        start: CGPoint(x: screen.midX, y: screen.maxY), end: CGPoint(x: screen.midX, y: screen.minY), options: [])
    cg.restoreGState()

    // --- the sun ---------------------------------------------------------
    // Eight rays, round-capped; outer tips end 156pt from centre, inside the 30pt bezel.
    // Below 64px the rays are a pixel wide and turn into noise, so those bitmaps get the
    // disc alone: at that size the icon is a coloured square with a warm dot in it anyway.
    let centre = CGPoint(x: 512, y: 552)
    let coreRadius: CGFloat = simplified ? 84 : 72
    let rayInner: CGFloat = 104
    let rayOuter: CGFloat = 156
    let rayWidth: CGFloat = 28

    if !simplified {
        cg.setStrokeColor(rgb(255, 196, 74))
        cg.setLineWidth(rayWidth)
        cg.setLineCap(.round)
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            cg.move(to: CGPoint(x: centre.x + cos(angle) * rayInner,
                                y: centre.y + sin(angle) * rayInner))
            cg.addLine(to: CGPoint(x: centre.x + cos(angle) * rayOuter,
                                   y: centre.y + sin(angle) * rayOuter))
            cg.strokePath()
        }
    }

    cg.saveGState()
    cg.addEllipse(in: CGRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                            width: coreRadius * 2, height: coreRadius * 2))
    cg.clip()
    cg.drawLinearGradient(
        gradient([rgb(255, 240, 168), rgb(255, 186, 56)], at: [0, 1]),
        start: CGPoint(x: centre.x, y: centre.y + coreRadius),
        end: CGPoint(x: centre.x, y: centre.y - coreRadius), options: [])
    cg.restoreGState()
}

func bitmap(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let scale = CGFloat(pixels) / canvas
    ctx.cgContext.scaleBy(x: scale, y: scale)
    draw(into: ctx.cgContext, simplified: pixels <= 32)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var cache: [Int: Data] = [:]
for variant in variants {
    let png = cache[variant.pixels] ?? bitmap(pixels: variant.pixels)
    cache[variant.pixels] = png
    try png.write(to: directory.appendingPathComponent(variant.name))
}
