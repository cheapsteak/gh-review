#!/usr/bin/env swift
import AppKit

func createAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext

    let cornerRadius = size * 0.195
    let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0),
        CGColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1.0)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    context.setStrokeColor(CGColor.white)
    context.setFillColor(CGColor.white)
    let scale = size / 512.0
    context.setLineWidth(24 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let centerX = 290 * scale
    let topY = 130 * scale
    let bottomY = 380 * scale
    context.move(to: CGPoint(x: centerX, y: topY))
    context.addLine(to: CGPoint(x: centerX, y: bottomY))
    context.strokePath()

    let leftX = 190 * scale
    let forkY = 200 * scale
    context.move(to: CGPoint(x: leftX, y: topY))
    context.addLine(to: CGPoint(x: leftX, y: forkY))
    context.addLine(to: CGPoint(x: centerX, y: forkY + 80 * scale))
    context.strokePath()

    let circleRadius = 22 * scale
    for point in [CGPoint(x: centerX, y: topY), CGPoint(x: centerX, y: bottomY), CGPoint(x: leftX, y: topY)] {
        context.fillEllipse(in: CGRect(x: point.x - circleRadius, y: point.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2))
    }

    context.setStrokeColor(CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0))
    context.setLineWidth(14 * scale)
    let checkX = centerX - 14 * scale
    let checkY = bottomY - 4 * scale
    context.move(to: CGPoint(x: checkX, y: checkY))
    context.addLine(to: CGPoint(x: checkX + 10 * scale, y: checkY - 12 * scale))
    context.addLine(to: CGPoint(x: checkX + 28 * scale, y: checkY + 14 * scale))
    context.strokePath()

    image.unlockFocus()
    return image
}

// Generate all required sizes for .icns
let sizes: [(CGFloat, String)] = [
    (16, "16x16"),
    (32, "16x16@2x"),
    (32, "32x32"),
    (64, "32x32@2x"),
    (128, "128x128"),
    (256, "128x128@2x"),
    (256, "256x256"),
    (512, "256x256@2x"),
    (512, "512x512"),
    (1024, "512x512@2x"),
]

let iconsetPath = "/tmp/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = createAppIcon(size: size)
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(name).png"))
}

// Convert iconset to icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", "/Users/chang/projects/gh-review/app/Resources/AppIcon.icns"]
try! process.run()
process.waitUntilExit()

print("Generated AppIcon.icns")
