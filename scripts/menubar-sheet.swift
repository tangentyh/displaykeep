#!/usr/bin/env swift
//
// menubar-sheet.swift — render docs/menubar.png: the menu bar as the three steady states show
// it, left to right — holding, armed, paused.
//
// The README table describes glyphs and opacities that live in DisplayKeep.swift, so the
// illustration is drawn from the same SF Symbols instead of being screenshotted: change a glyph
// and re-run this rather than hunting for three menu bar states to capture. The dimming of the
// idle states is AppKit's own (`appearsDisabled`), which cannot be rendered outside a status
// item, so the two idle cells approximate it.
//
// usage: swift scripts/menubar-sheet.swift [output.png]   (default docs/menubar.png)

import AppKit

let states: [(symbol: String, dim: Bool)] = [
    ("display", false),      // holding
    ("display", true),       // armed
    ("pause.circle", true),  // paused
]

// 402x52px is the size the README has always used for this image: 3 cells of 67pt at 2x.
let scale = 2
let cell = NSSize(width: 67, height: 26)
let size = NSSize(width: cell.width * CGFloat(states.count), height: cell.height)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

// Dark menu bar, plus the hairline between items that three separate captures would show.
NSColor(srgbRed: 0x11 / 255.0, green: 0x24 / 255.0, blue: 0x48 / 255.0, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
NSColor(srgbRed: 0x0D / 255.0, green: 0x1D / 255.0, blue: 0x3B / 255.0, alpha: 1).setFill()
for i in 1..<states.count {
    let x = CGFloat(i) * cell.width - 0.5
    NSRect(x: x, y: 0, width: 0.5, height: size.height).fill()
}

for (i, state) in states.enumerated() {
    guard let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) else {
        FileHandle.standardError.write("missing SF Symbol \(state.symbol)\n".data(using: .utf8)!)
        exit(1)
    }
    image.isTemplate = true
    // Template glyphs are masks; tint them the way the status bar does — normal, or faded for
    // the states the app draws with `appearsDisabled`.
    let tint = NSColor(white: 1, alpha: state.dim ? 0.45 : 0.97)
    let tinted = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let origin = NSPoint(x: CGFloat(i) * cell.width + (cell.width - image.size.width) / 2,
                         y: (cell.height - image.size.height) / 2)
    tinted.draw(in: NSRect(origin: origin, size: image.size))
}

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/menubar.png"
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: url)
