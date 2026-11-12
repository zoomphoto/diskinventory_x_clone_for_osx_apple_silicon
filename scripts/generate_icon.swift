#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

struct CushionBlock {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
    let topColor: (CGFloat, CGFloat, CGFloat)
    let bottomColor: (CGFloat, CGFloat, CGFloat)
}

let blocks: [CushionBlock] = [
    CushionBlock(x: 0.00, y: 0.38, w: 0.56, h: 0.62, topColor: (0.28, 0.62, 0.98), bottomColor: (0.11, 0.32, 0.68)),
    CushionBlock(x: 0.59, y: 0.38, w: 0.41, h: 0.62, topColor: (0.96, 0.36, 0.32), bottomColor: (0.62, 0.14, 0.14)),
    CushionBlock(x: 0.00, y: 0.00, w: 0.36, h: 0.35, topColor: (0.70, 0.42, 0.96), bottomColor: (0.40, 0.18, 0.66)),
    CushionBlock(x: 0.39, y: 0.00, w: 0.35, h: 0.35, topColor: (0.98, 0.72, 0.24), bottomColor: (0.68, 0.42, 0.08)),
    CushionBlock(x: 0.77, y: 0.00, w: 0.23, h: 0.35, topColor: (0.28, 0.84, 0.52), bottomColor: (0.12, 0.48, 0.26))
]

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let inset = s * 0.09
    let cardRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = cardRect.width * 0.225

    // Subtle drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.045, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
    let bgPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Background metallic gradient
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.18, green: 0.20, blue: 0.26, alpha: 1.0),
        CGColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )
    }

    // Inner treemap blocks
    let pad = cardRect.width * 0.10
    let inner = cardRect.insetBy(dx: pad, dy: pad)
    let blockRadius = max(1.5, inner.width * 0.055)

    for b in blocks {
        let r = CGRect(
            x: inner.minX + inner.width * b.x,
            y: inner.minY + inner.height * b.y,
            width: inner.width * b.w,
            height: inner.height * b.h
        )
        let p = CGPath(roundedRect: r, cornerWidth: blockRadius, cornerHeight: blockRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        let cArr = [
            CGColor(red: b.topColor.0, green: b.topColor.1, blue: b.topColor.2, alpha: 1.0),
            CGColor(red: b.bottomColor.0, green: b.bottomColor.1, blue: b.bottomColor.2, alpha: 1.0)
        ] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: cArr, locations: [0, 1]) {
            ctx.drawLinearGradient(
                g,
                start: CGPoint(x: r.minX, y: r.maxY),
                end: CGPoint(x: r.maxX, y: r.minY),
                options: []
            )
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(max(1, s * 0.008))
        ctx.addPath(p)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Outer subtle rim highlight
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(max(1, s * 0.01))
    ctx.addPath(bgPath)
    ctx.strokePath()
    ctx.restoreGState()

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in specs {
    if let pngData = renderIcon(pixelSize: size) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try pngData.write(to: outURL)
    }
}

