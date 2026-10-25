import CoreGraphics
import Foundation
import ImageIO
import Metal
import PresenterCore
import RenderEngine
import Testing
import UniformTypeIdentifiers
import simd
@testable import SlideScene

// A series theme made from art, rendered the way the audience screen and
// the livestream draw it. The report: the scripture slide on the audience
// screen showed the cream series art and no verse, and the livestream's
// verse was a dim grey under its navy bar. The renderer draws a design's
// objects in order, the last on top, and the designs listed their text
// first, so the art covered it.
//
// Set SERIES_EVIDENCE_DIR to keep the rendered slides as PNGs.

/// Series art held in memory, served to the compositor as library media is.
private final class ArtSource: MediaTextureSource, @unchecked Sendable {
    private var surfaces: [String: MediaSurface] = [:]

    init(device: MTLDevice, images: [String: CGImage]) {
        for (id, image) in images {
            guard let space = CGColorSpace(name: CGColorSpace.displayP3),
                  let context = CGContext(
                    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let texture = device.makeTexture(descriptor: {
                      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                          pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
                      descriptor.usage = .shaderRead
                      return descriptor
                  }())
            else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else { continue }
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: context.bytesPerRow)
            surfaces[id] = .bgra(texture: texture, transform: VideoColorTransform(
                ycbcrMatrix: matrix_identity_float3x3, ycbcrOffset: .zero,
                gamutToWorking: matrix_identity_float3x3, premultipliedAlpha: true), retained: [])
        }
    }

    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { surfaces[mediaID] }
    func liveCadence(for mediaID: String) -> LiveCadence? { nil }
}

enum SampleArt: String, CaseIterable, Sendable {
    case light, dark, busy

    /// What Claude (or the palette) asked for: white text everywhere, the
    /// wrong answer on cream.
    var askedTextColor: String { "#FFFFFFFF" }

    var tone: ArtAnalysis.Tone { self == .light ? .light : .dark }

    func image() -> CGImage {
        let context = bitmap(1920, 1080)!
        func fill(_ hex: String, _ rect: CGRect) {
            let color = SeriesColor(hex: hex)!
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.fill(rect)
        }
        func ellipse(_ hex: String, _ rect: CGRect) {
            let color = SeriesColor(hex: hex)!
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.fillEllipse(in: rect)
        }
        switch self {
        case .light:
            fill("#F3ECDD", CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ellipse("#EADFC8", CGRect(x: 1180, y: -260, width: 1100, height: 1100))
            ellipse("#F8F4EA", CGRect(x: -300, y: 500, width: 900, height: 900))
            fill("#C9A46A", CGRect(x: 0, y: 0, width: 1920, height: 18))
        case .dark:
            fill("#0D1A33", CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ellipse("#16284A", CGRect(x: 900, y: -200, width: 1300, height: 1300))
            fill("#D9A441", CGRect(x: 0, y: 0, width: 1920, height: 14))
        case .busy:
            // Stripes of black, white, brick, steel and grey: no one text
            // color reads on all of it.
            let colors = ["#111111", "#F2F2F2", "#9A3B2E", "#3E6A9E", "#7A7A7A", "#D8C05A"]
            for (index, x) in stride(from: -1080, to: 1920, by: 90).enumerated() {
                let color = SeriesColor(hex: colors[index % colors.count])!
                context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
                context.beginPath()
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x + 90, y: 0))
                context.addLine(to: CGPoint(x: x + 90 + 1080, y: 1080))
                context.addLine(to: CGPoint(x: x + 1080, y: 1080))
                context.closePath()
                context.fillPath()
            }
        }
        return context.makeImage()!
    }
}

private func bitmap(_ width: Int, _ height: Int) -> CGContext? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// Colors on a grid inside a box of a 1920×1080 image, as the app measures
/// the art where text sits (SeriesArt.samples).
private func samples(of image: CGImage, in box: PhotoSeriesTheme.Box) -> [SeriesColor] {
    let columns = 96, rows = 54
    guard let context = bitmap(columns, rows), let data = context.data else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
    let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * rows)
    var colors: [SeriesColor] = []
    let firstRow = Int(box.y / 1080 * Double(rows)), lastRow = min(rows, Int(((box.y + box.height) / 1080 * Double(rows)).rounded(.up)))
    let firstColumn = Int(box.x / 1920 * Double(columns))
    let lastColumn = min(columns, Int(((box.x + box.width) / 1920 * Double(columns)).rounded(.up)))
    for row in firstRow..<lastRow {
        for column in firstColumn..<lastColumn {
            let offset = row * context.bytesPerRow + column * 4
            colors.append(SeriesColor(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
                                      blue: Double(bytes[offset + 2]) / 255))
        }
    }
    return colors
}

/// The theme PhotoSeries.save builds from the art: the art as the Title
/// slide and, left sharp as a designed background is, behind the text.
private func seriesTheme(_ art: SampleArt, image: CGImage) -> Theme {
    var analysis = ArtAnalysis.local(
        swatches: SeriesPalette.extract(samples(of: image, in: (0, 0, 1920, 1080)), count: 6), seriesTitle: "Rooted")
    analysis.textColor = art.askedTextColor
    analysis.textBackground = .init(kind: .blurredArt, tone: art.tone, strength: 0, blur: 0, colors: [])
    analysis.artHasTitle = false
    analysis = analysis.sanitized(installedFamilies: ["Helvetica Neue"])
    let titleBox = PhotoSeriesTheme.titleBox(for: analysis, artWidth: 1920, artHeight: 1080)
    return PhotoSeriesTheme.make(PhotoSeriesTheme.Input(
        name: "Rooted", analysis: analysis, headingFont: "HelveticaNeue-Bold", bodyFont: "HelveticaNeue",
        verseFont: "HelveticaNeue-Italic", titleArtMediaID: "title-art", artWidth: 1920, artHeight: 1080,
        textBackgroundMediaID: "soft-art", textBackgroundSamples: samples(of: image, in: (160, 170, 1600, 740)),
        titleSamples: samples(of: image, in: titleBox)), id: "series-\(art.rawValue)")
}

private let revelation = BiblePassage(
    reference: BibleReference.parse("Revelation 2:5")!,
    translation: BibleTranslation(source: .esv, id: "ESV", abbreviation: "ESV", name: "ESV"),
    verses: [BibleVerse(chapter: 2, verse: 5, text: "Remember therefore from where you have fallen; repent, and do the works you did at first. If not, I will come to you and remove your lampstand from its place, unless you repent.")])

@MainActor
private struct Renderer {
    let compositor: Compositor
    let source: ArtSource
    static let size = (width: 960, height: 540)

    init?(images: [String: CGImage]) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        compositor = try Compositor(device: device)
        source = ArtSource(device: device, images: images)
        compositor.mediaSource = source
    }

    func render(_ slide: Slide, theme: Theme, presentation: Presentation? = nil) throws -> RenderedFrame {
        let scene = SlideSceneBuilder.scene(for: slide, theme: theme, presentation: presentation,
                                            canvasSize: CGSize(width: 1920, height: 1080))
        return try compositor.renderFrame(scene: scene, width: Self.size.width, height: Self.size.height)
    }
}

/// Linear-light luminance of each pixel (the frame is linear Display P3).
private func luminance(_ frame: RenderedFrame) -> [Double] {
    var values = [Double](repeating: 0, count: frame.width * frame.height)
    frame.data.withUnsafeBytes { raw in
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let pixel = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
                let (r, g, b) = (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
                values[y * frame.width + x] = min(1, max(0, 0.2289746 * r + 0.6917385 * g + 0.0792869 * b))
            }
        }
    }
    return values
}

/// The text's contrast with what's behind it: the slide rendered with and
/// without its words, compared pixel by pixel inside the box (slide points)
/// where the words changed the picture. The 90th percentile, so the solid
/// middle of the letters counts and their soft edges don't. Nil when the
/// words changed nothing: they weren't drawn, or were drawn under the art.
private func textContrast(with: RenderedFrame, without: RenderedFrame,
                          in box: (x: Double, y: Double, width: Double, height: Double)) -> (contrast: Double, pixels: Int)? {
    let a = luminance(with), b = luminance(without)
    let scale = Double(with.width) / 1920
    var ratios: [Double] = []
    for y in Int(box.y * scale)..<min(with.height, Int((box.y + box.height) * scale)) {
        for x in Int(box.x * scale)..<min(with.width, Int((box.x + box.width) * scale)) {
            let index = y * with.width + x
            guard abs(a[index] - b[index]) > 0.01 else { continue }
            ratios.append((max(a[index], b[index]) + 0.05) / (min(a[index], b[index]) + 0.05))
        }
    }
    guard ratios.count > 200 else { return nil }
    ratios.sort()
    return (ratios[Int(Double(ratios.count - 1) * 0.9)], ratios.count)
}

private func save(_ frame: RenderedFrame, _ name: String) {
    guard let folder = ProcessInfo.processInfo.environment["SERIES_EVIDENCE_DIR"], !folder.isEmpty,
          let image = frame.cgImage, let context = bitmap(frame.width, frame.height) else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    guard let flat = context.makeImage() else { return }
    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, flat, nil)
    CGImageDestinationFinalize(destination)
}

@MainActor
struct SeriesThemeRenderTests {
    @Test(arguments: SampleArt.allCases)
    func scriptureOnTheAudienceScreenShowsItsVerse(_ art: SampleArt) throws {
        let image = art.image()
        guard let renderer = try Renderer(images: ["title-art": image, "soft-art": image]) else { return }
        let theme = seriesTheme(art, image: image)
        let presentation = ScriptureSlideBuilder.presentation(for: revelation, format: ScriptureFormat(), theme: theme)
        let slide = try #require(presentation.slides.first)
        #expect(slide.objects.map(\.name) == ["Verse", "Reference"])

        let shown = try renderer.render(slide, theme: theme, presentation: presentation)
        var empty = slide
        empty.objects = []
        let bare = try renderer.render(empty, theme: theme, presentation: presentation)
        save(shown, "\(art.rawValue)-scripture-audience")

        let measured = textContrast(with: shown, without: bare, in: (220, 230, 1480, 540))
        #expect(measured != nil, "\(art): the verse is drawn on the audience screen")
        // Verses are held to 7:1 for the projector; the reference to 4.5:1.
        #expect((measured?.contrast ?? 0) >= 7, "\(art): the verse reads at \(measured?.contrast ?? 0):1")
        let reference = textContrast(with: shown, without: bare, in: (220, 800, 1480, 70))
        #expect((reference?.contrast ?? 0) >= 4.5, "\(art): the reference reads at \(reference?.contrast ?? 0):1")

        // On busy art the verse sits on a plate, not straight on the stripes.
        let bible = try #require(theme.slides?.first { $0.name == "Bible" && $0.folder == nil })
        let plate = bible.objects.first { $0.name == "Scrim" && ($0.width ?? 1920) < 1920 }
        #expect((plate != nil) == (art == .busy), "\(art): a plate only where the art is busy")
    }

    @Test(arguments: SampleArt.allCases)
    func scriptureOnTheLivestreamReadsOnItsBar(_ art: SampleArt) throws {
        let image = art.image()
        guard let renderer = try Renderer(images: ["title-art": image, "soft-art": image]) else { return }
        let theme = seriesTheme(art, image: image)
        let stream = ThemeCategories.lowerThirds(of: theme)
        let presentation = ScriptureSlideBuilder.presentation(for: revelation, format: ScriptureFormat(), theme: theme)
        let slide = try #require(presentation.slides.first)
        let shown = try renderer.render(slide, theme: stream, presentation: presentation)
        var empty = slide
        empty.objects = []
        let bare = try renderer.render(empty, theme: stream, presentation: presentation)
        save(shown, "\(art.rawValue)-scripture-lower-third")

        let measured = textContrast(with: shown, without: bare, in: (80, 860, 1760, 220))
        #expect(measured != nil, "\(art): the verse is drawn on the bar")
        #expect((measured?.contrast ?? 0) >= 4.5, "\(art): the verse reads at \(measured?.contrast ?? 0):1, not dimmed by the bar")
    }

    @Test(arguments: SampleArt.allCases)
    func everyAudienceDesignShowsItsWords(_ art: SampleArt) throws {
        let image = art.image()
        guard let renderer = try Renderer(images: ["title-art": image, "soft-art": image]) else { return }
        let theme = seriesTheme(art, image: image)
        let words: [String: [String: String]] = [
            SermonSeriesTheme.titleCategory: ["Title": "Remember", "Subtitle": "Rooted"],
            SermonSeriesTheme.pointCategory: ["Point": "Return to your first love"],
            SermonSeriesTheme.pointScriptureCategory: [
                "Point": "Repent", "Verse": "Remember therefore from where you have fallen", "Reference": "Revelation 2:5"],
            SermonSeriesTheme.worshipCategory: ["Lyrics": "Great is thy faithfulness\nMorning by morning"],
        ]
        for (category, texts) in words.sorted(by: { $0.key < $1.key }) {
            let design = try #require(theme.slides?.first { $0.name == category && $0.folder == nil })
            let slide = Slide(id: "s-\(category)", name: category,
                              objects: texts.sorted { $0.key < $1.key }.map {
                                  SlideObject(id: UUID().uuidString, objectKind: .text, name: $0.key, text: $0.value)
                              },
                              themeSlideName: category)
            let shown = try renderer.render(slide, theme: theme)
            var empty = slide
            empty.objects = []
            let bare = try renderer.render(empty, theme: theme)
            save(shown, "\(art.rawValue)-\(category.lowercased().replacingOccurrences(of: " ", with: "-"))")
            for object in design.objects where object.objectKind == .text && texts[object.name] != nil {
                let box = (object.x ?? 0, object.y ?? 0, object.width ?? 1920, object.height ?? 1080)
                let measured = textContrast(with: shown, without: bare, in: box)
                #expect(measured != nil, "\(art) \(category): \(object.name) is drawn")
                // Body text 7:1; the title over the art and accent lines 4.5:1.
                let body = ["Point", "Verse", "Lyrics"].contains(object.name)
                #expect((measured?.contrast ?? 0) >= (body ? 7 : 4.5),
                        "\(art) \(category): \(object.name) reads at \(measured?.contrast ?? 0):1")
            }
        }
    }
}
