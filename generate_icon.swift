// One-off helper: renders AppIcon.icns for UTM Studio.app.
// Run with: swift generate_icon.swift <output .iconset dir>
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.53, green: 0.28, blue: 0.86, alpha: 1.0)
    ])
    gradient?.draw(in: rect, angle: -60)

    // Two overlapping "window" cards to suggest Master + linked clone.
    func drawCard(rect: NSRect, alpha: CGFloat, filled: Bool) {
        let card = NSBezierPath(roundedRect: rect, xRadius: size * 0.045, yRadius: size * 0.045)
        NSColor.white.withAlphaComponent(alpha).setFill()
        card.fill()
        if !filled {
            NSColor.white.withAlphaComponent(min(alpha + 0.15, 1)).setStroke()
            card.lineWidth = max(size * 0.008, 1)
            card.stroke()
        }
    }

    let backW = size * 0.46
    let backH = size * 0.34
    drawCard(rect: NSRect(x: size * 0.30, y: size * 0.50, width: backW, height: backH), alpha: 0.35, filled: false)

    let frontW = size * 0.50
    let frontH = size * 0.37
    drawCard(rect: NSRect(x: size * 0.20, y: size * 0.24, width: frontW, height: frontH), alpha: 0.96, filled: true)

    // Little "play" glyph inside the front card to suggest launching a client.
    let playSize = frontH * 0.42
    let cx = size * 0.20 + frontW * 0.5
    let cy = size * 0.24 + frontH * 0.5
    let play = NSBezierPath()
    play.move(to: NSPoint(x: cx - playSize * 0.32, y: cy + playSize * 0.5))
    play.line(to: NSPoint(x: cx - playSize * 0.32, y: cy - playSize * 0.5))
    play.line(to: NSPoint(x: cx + playSize * 0.55, y: cy))
    play.close()
    NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.98, alpha: 1.0).setFill()
    play.fill()

    image.unlockFocus()
    return image
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

for (px, name) in sizes {
    let image = makeIcon(size: CGFloat(px))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
    try? png.write(to: url)
}

print("Wrote iconset to \(outputDir)")
