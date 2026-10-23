import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The phone remote's home-screen icon: a blue screen with a white Next
/// arrow on the remote's dark background. Drawn here rather than shipped as
/// a file, so the package carries no image resources; each size is drawn once.
public enum RemoteIcon {
    /// iOS asks for /apple-touch-icon.png by itself; Android reads the
    /// manifest's 192 and 512.
    public static let paths: [(path: String, size: Int)] = [
        ("/apple-touch-icon.png", 180),
        ("/remote-icon-192.png", 192),
        ("/remote-icon-512.png", 512),
    ]

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var pngs: [Int: Data] = [:]
    }

    private static let cache = Cache()

    public static func png(size: Int) -> Data? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let hit = cache.pngs[size] { return hit }
        guard let data = draw(size: size) else { return nil }
        cache.pngs[size] = data
        return data
    }

    private static func draw(size: Int) -> Data? {
        let side = CGFloat(size)
        guard size > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Square and opaque: iOS rounds the corners itself.
        context.setFillColor(CGColor(srgbRed: 0x0B / 255, green: 0x0D / 255, blue: 0x10 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let screen = CGRect(x: side * 0.14, y: side * 0.27, width: side * 0.72, height: side * 0.46)
        context.addPath(CGPath(roundedRect: screen, cornerWidth: side * 0.07, cornerHeight: side * 0.07, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0, green: 130.0 / 255, blue: 202.0 / 255, alpha: 1))
        context.fillPath()

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: side * 0.44, y: side * 0.38))
        arrow.addLine(to: CGPoint(x: side * 0.62, y: side * 0.50))
        arrow.addLine(to: CGPoint(x: side * 0.44, y: side * 0.62))
        arrow.closeSubpath()
        context.addPath(arrow)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
