import AppKit
import CoreImage
import ImageIO
import PresenterCore
import UniformTypeIdentifiers

/// A sermon series graphic, read once from a JPG, PNG, HEIC or PDF and
/// turned into what a series made from a photo needs: a small copy for
/// Claude to look at, its pixels for the palette, the art cropped for the
/// Title slide, and a soft version of it for text slides. All of it is
/// pure image work, so it runs off the main thread.
struct SeriesArt: @unchecked Sendable {
    let image: CGImage
    let fileName: String
    var width: Int { image.width }
    var height: Int { image.height }

    static let types: [UTType] = [.jpeg, .png, .heic, .tiff, .pdf, .webP]

    static func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    enum ReadError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name) as an image."
            }
        }
    }

    /// Loads the art, the first page for a PDF. Large images are read at up
    /// to 4096 pixels across: plenty for a 1920×1080 slide.
    static func load(_ url: URL) throws -> SeriesArt {
        let name = url.lastPathComponent
        if UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1), let image = render(page) else {
                throw ReadError.unreadable(name)
            }
            return SeriesArt(image: image, fileName: name)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
        else { throw ReadError.unreadable(name) }
        return SeriesArt(image: image, fileName: name)
    }

    /// A PDF page on white (a designer's PDF often leaves the page
    /// transparent), about 3000 pixels across.
    private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = 3000 / max(box.width, box.height)
        let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
        guard let context = bitmap(width: Int(size.width), height: Int(size.height)) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: For Claude

    /// A JPEG no more than 1568 pixels on its long edge, the most Claude
    /// looks at before scaling an image down itself.
    func jpegForClaude() -> (data: Data, width: Int, height: Int)? {
        let scale = min(1, 1568 / Double(max(width, height)))
        let size = (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
        guard let context = Self.bitmap(width: size.0, height: size.1) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
        guard let small = context.makeImage(), let data = Self.jpeg(small, quality: 0.85) else { return nil }
        return (data, size.0, size.1)
    }

    // MARK: Palette

    /// The art's colors, from a 64-pixel-wide copy; see-through pixels
    /// (a PNG with a transparent edge) are left out.
    func pixels() -> [SeriesColor] {
        let columns = 64
        let rows = max(1, Int((Double(height) / Double(width) * 64).rounded()))
        return Self.samples(of: image, columns: columns, rows: rows, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: Slides

    /// The art cropped to 16:9 around its focus point at 1920×1080: the
    /// Title slide's background.
    func titleArt(focusX: Double, focusY: Double) -> CGImage? {
        let visible = ArtCrop.visible(imageWidth: Double(width), imageHeight: Double(height), focusX: focusX, focusY: focusY)
        let crop = CGRect(x: visible.x * Double(width), y: visible.y * Double(height),
                          width: visible.width * Double(width), height: visible.height * Double(height)).integral
        guard let cropped = image.cropping(to: crop),
              let context = Self.bitmap(width: 1920, height: 1080) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        return context.makeImage()
    }

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// The title art blurred and dimmed (or washed toward white) so lines
    /// of text read on it, with a soft vignette on the dark version to hold
    /// the eye in the middle.
    static func softBackground(from titleArt: CGImage, tone: ArtAnalysis.Tone, strength: Double, blur: Double) -> CGImage? {
        let source = CIImage(cgImage: titleArt)
        let extent = source.extent
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 18 + blur * 72)
            .cropped(to: extent)
        let veil = tone == .dark
            ? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.2 + 0.65 * strength))
            : CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.35 + 0.55 * strength))
        var output = veil.cropped(to: extent).composited(over: blurred)
        if tone == .dark {
            output = output.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 0.2 + 0.4 * strength, kCIInputRadiusKey: 2.2,
            ])
        }
        return context.createCGImage(output, from: extent)
    }

    // MARK: Measuring

    /// Colors on a grid across part of a 1920×1080 image, given in slide
    /// points, so text can be checked against what's really behind it.
    static func samples(of slideImage: CGImage, in box: PhotoSeriesTheme.Box) -> [SeriesColor] {
        let unit = CGRect(x: box.x / 1920, y: box.y / 1080, width: box.width / 1920, height: box.height / 1080)
        return samples(of: slideImage, columns: 96, rows: 54, in: unit).enumerated()
            .filter { $0.offset % 3 == 0 }.map(\.element)
    }

    /// Where body text sits on the Point, Scripture and Worship designs.
    static let textArea: PhotoSeriesTheme.Box = (160, 170, 1600, 740)

    private static func samples(of image: CGImage, columns: Int, rows: Int, in unit: CGRect) -> [SeriesColor] {
        guard let context = bitmap(width: columns, height: rows), let data = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * rows)
        var colors: [SeriesColor] = []
        // Bitmap rows run top down in memory; `unit` is measured from the top.
        let firstRow = Int((unit.minY * Double(rows)).rounded(.down))
        let lastRow = min(rows, Int((unit.maxY * Double(rows)).rounded(.up)))
        let firstColumn = Int((unit.minX * Double(columns)).rounded(.down))
        let lastColumn = min(columns, Int((unit.maxX * Double(columns)).rounded(.up)))
        guard firstRow < lastRow, firstColumn < lastColumn else { return [] }
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                let offset = row * context.bytesPerRow + column * 4
                let alpha = Double(bytes[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                // Premultiplied, so divided back out.
                colors.append(SeriesColor(red: Double(bytes[offset]) / 255 / alpha,
                                          green: Double(bytes[offset + 1]) / 255 / alpha,
                                          blue: Double(bytes[offset + 2]) / 255 / alpha))
            }
        }
        return colors
    }

    // MARK: Files

    static func jpeg(_ image: CGImage, quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Fonts for a series made from a photo.
@MainActor
enum SeriesFonts {
    /// Installed families that can set a title or a paragraph: Latin
    /// letters, not symbols, emoji or the system's hidden faces.
    static let families: [String] = {
        let skip = ["emoji", "symbol", "dingbat", "wingding", "webding", "ornament", "lastresort", "braille",
                    "math", "icons"]
        let latin = CharacterSet(charactersIn: "AZaz09")
        return NSFontManager.shared.availableFontFamilies.filter { family in
            let lower = family.lowercased()
            guard !family.hasPrefix("."), !skip.contains(where: lower.contains) else { return false }
            guard let face = (NSFontManager.shared.availableMembers(ofFontFamily: family)?.first?.first as? String)
                .flatMap({ NSFont(name: $0, size: 12) }) else { return false }
            return face.coveredCharacterSet.isSuperset(of: latin)
        }
    }()

    /// The family's face nearest the weight, upright or italic, as a
    /// PostScript name. Falls back to the family's regular face, then to
    /// Helvetica Neue.
    static func face(_ family: String, weight: ArtAnalysis.Weight, italic: Bool = false) -> String {
        let target: Int = switch weight {
        case .light: 3
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 11
        case .black: 12
        }
        let members = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> (name: String, weight: Int, italic: Bool, condensed: Bool)? in
            guard let name = member.first as? String, let weight = member.dropFirst(2).first as? Int,
                  let traits = member.dropFirst(3).first as? UInt else { return nil }
            let mask = NSFontTraitMask(rawValue: traits)
            return (name, weight, mask.contains(.italicFontMask), mask.contains(.condensedFontMask) || mask.contains(.narrowFontMask))
        }
        let matching = members.filter { $0.italic == italic }
        let pool = matching.isEmpty ? members : matching
        let best = pool.min { a, b in
            let da = abs(a.weight - target), db = abs(b.weight - target)
            return da != db ? da < db : (!a.condensed && b.condensed)
        }
        return best?.name ?? NSFont(name: family, size: 12)?.fontName ?? "HelveticaNeue"
    }
}
