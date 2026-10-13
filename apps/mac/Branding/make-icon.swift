// Draws the Screens app icon at every size the asset catalog needs.
//   swift apps/mac/Branding/make-icon.swift apps/mac/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let output = CommandLine.arguments.dropFirst().first ?? "."

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// Drawn on a 1024 grid (origin bottom-left), scaled to the target size.
func draw(_ context: CGContext) {
    // Apple's icon grid: an 824 pt rounded square with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x2B3FD6))
    context.fillPath()
    context.restoreGState()
    linearGradient(context, tilePath, [color(0x2F6BFF), color(0x6A3DF0), color(0xE2408C)],
                   from: CGPoint(x: 140, y: 900), to: CGPoint(x: 900, y: 120))
    // A soft light behind the screen.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 600), endRadius: 420, options: [])
    context.restoreGState()

    // Stand.
    context.setFillColor(color(0xFFFFFF, 0.92))
    context.addPath(roundedRect(CGRect(x: 470, y: 268, width: 84, height: 90), 10))
    context.fillPath()
    context.addPath(roundedRect(CGRect(x: 372, y: 240, width: 280, height: 42), 21))
    context.fillPath()

    // Screen: white bezel, dark slide.
    let bezel = CGRect(x: 212, y: 340, width: 600, height: 400)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x10093A, 0.45))
    context.addPath(roundedRect(bezel, 46))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    let slide = bezel.insetBy(dx: 30, dy: 30)
    let slidePath = roundedRect(slide, 22)
    linearGradient(context, slidePath, [color(0x141B3D), color(0x231A52)],
                   from: CGPoint(x: slide.minX, y: slide.maxY), to: CGPoint(x: slide.maxX, y: slide.minY))

    // Title lines on the slide.
    context.setFillColor(color(0xFFFFFF, 0.9))
    context.addPath(roundedRect(CGRect(x: slide.minX + 60, y: slide.maxY - 110, width: 300, height: 34), 17))
    context.fillPath()
    context.setFillColor(color(0xFFFFFF, 0.45))
    context.addPath(roundedRect(CGRect(x: slide.minX + 60, y: slide.maxY - 160, width: 210, height: 24), 12))
    context.fillPath()

    // The lower third: a warm bar with a light text line.
    let bar = CGRect(x: slide.minX + 36, y: slide.minY + 34, width: slide.width - 72, height: 76)
    let barPath = roundedRect(bar, 18)
    linearGradient(context, barPath, [color(0xFFB21E), color(0xFF6A3D)],
                   from: CGPoint(x: bar.minX, y: bar.midY), to: CGPoint(x: bar.maxX, y: bar.midY))
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.addPath(roundedRect(CGRect(x: bar.minX + 30, y: bar.midY - 11, width: 260, height: 22), 11))
    context.fillPath()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for size in sizes {
    let pixels = size.pixels
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(context)
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: output).appendingPathComponent(size.name))
}
print("Wrote \(sizes.count) icons to \(output)")
