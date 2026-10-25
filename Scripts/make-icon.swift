#!/usr/bin/env swift
//
// Draws Battery Trace's icon into App/Assets.xcassets/AppIcon.appiconset.
//
// In code rather than a pile of hand-made PNGs, so it re-renders at any size.
// The same family as NetworkMonitor's: a dark squircle, its green (#51FF70) and
// light grey (#E5E5E5). A battery outline with a power trace running through it.
//
// Run:  swift Scripts/make-icon.swift
// The PNGs it writes are committed, so a normal build never needs this script.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

let traceColor = CGColor(red: 0x51 / 255, green: 0xFF / 255, blue: 0x70 / 255, alpha: 1)
let outlineColor = CGColor(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xE5 / 255, alpha: 1)
let backgroundTop = CGColor(red: 0.19, green: 0.19, blue: 0.20, alpha: 1)
let backgroundBottom = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)

// MARK: - Geometry, on a 1024 grid

let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100

/// Apple's icon shape is a squircle; a superellipse with n ≈ 6.2 matches it.
func squirclePath(in rect: CGRect, n: CGFloat = 6.2, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let exponent = 2 / n
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), exponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The battery's body, wide and short, with its terminal on the right.
/// Strokes are 64 units: exactly one pixel at 16 px.
let batteryBody = CGRect(x: 182, y: 337, width: 600, height: 350)
let terminal = CGRect(x: 782 + 22, y: 437, width: 52, height: 150)
let stroke: CGFloat = 64

/// The trace: flat, a small rise, a tall spike, a dip, and back to a level,
/// as a power reading over time looks. Inside the body, clear of its outline.
func tracePath() -> CGPath {
    let inner = batteryBody.insetBy(dx: stroke * 1.5, dy: stroke * 1.4)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: inner.minX + inner.width * x, y: inner.minY + inner.height * y)
    }
    let path = CGMutablePath()
    path.move(to: p(0, 0.38))
    path.addLine(to: p(0.22, 0.38))
    path.addLine(to: p(0.34, 0.62))
    path.addLine(to: p(0.46, 0.18))
    path.addLine(to: p(0.58, 1.0))
    path.addLine(to: p(0.70, 0.0))
    path.addLine(to: p(0.80, 0.50))
    path.addLine(to: p(1.0, 0.50))
    return path
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, pixelSize: CGFloat) {
    ctx.scaleBy(x: pixelSize / canvas, y: pixelSize / canvas)
    ctx.setShouldAntialias(true)

    let body = CGRect(x: bodyInset, y: bodyInset, width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    ctx.saveGState()
    ctx.addPath(squirclePath(in: body))
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [backgroundTop, backgroundBottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    }
    ctx.restoreGState()

    // Battery outline and terminal.
    ctx.setStrokeColor(outlineColor)
    ctx.setLineWidth(stroke)
    ctx.addPath(CGPath(roundedRect: batteryBody.insetBy(dx: stroke / 2, dy: stroke / 2),
                       cornerWidth: 70, cornerHeight: 70, transform: nil))
    ctx.strokePath()
    ctx.setFillColor(outlineColor)
    ctx.addPath(CGPath(roundedRect: terminal, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.fillPath()

    // The trace.
    ctx.setStrokeColor(traceColor)
    ctx.setLineWidth(56)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(tracePath())
    ctx.strokePath()
}

func renderPNG(pixelSize: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(pixelSize) px context")
    }
    drawIcon(in: ctx, pixelSize: CGFloat(pixelSize))
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not finalize \(url.path)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("App/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")

do {
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            try renderPNG(pixelSize: base * scale, to: iconSet.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
        }
    }
    let info = ["author": "xcode", "version": 1] as [String: Any]
    let contents = try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    try contents.write(to: iconSet.appendingPathComponent("Contents.json"))
    try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
        .write(to: catalog.appendingPathComponent("Contents.json"))
    try renderPNG(pixelSize: 256, to: root.appendingPathComponent("docs/images/icon.png"))
    print("==> Wrote \(iconSet.path) and docs/images/icon.png")
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
