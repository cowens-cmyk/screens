import AppKit
import PresenterCore

/// Staff's picks from Adjust Colors.
struct PhotoSeriesOverrides: Equatable {
    var text: SeriesColor?
    var accent: SeriesColor?
    var bar: SeriesColor?
}

/// A series made from a photo, read and rendered but not yet in the
/// library: the preview shows it, Use This Series saves it.
struct PhotoSeriesDraft: @unchecked Sendable {
    var art: SeriesArt
    /// Sanitized, with the dimming strength the contrast check settled on.
    var analysis: ArtAnalysis
    var titleArt: CGImage
    /// The blurred art, when the analysis chose it for text slides.
    var softBackground: CGImage?
    var headingFont: String
    var bodyFont: String
    var verseFont: String
    var titleSamples: [SeriesColor]
    var backgroundSamples: [SeriesColor]
    /// Whether Claude read the art, or only its colors were used.
    var readByClaude: Bool
    var note: String?

    /// Stand-in media ids for the preview, before anything is imported.
    static let previewTitleID = "photo-series-preview-title"
    static let previewBackgroundID = "photo-series-preview-background"

    var previewImages: [String: CGImage] {
        var images = [Self.previewTitleID: titleArt]
        if let softBackground { images[Self.previewBackgroundID] = softBackground }
        return images
    }

    func input(name: String, titleArtID: String?, backgroundID: String?, overrides: PhotoSeriesOverrides) -> PhotoSeriesTheme.Input {
        PhotoSeriesTheme.Input(
            name: name, analysis: analysis, headingFont: headingFont, bodyFont: bodyFont, verseFont: verseFont,
            titleArtMediaID: titleArtID, artWidth: Double(art.width), artHeight: Double(art.height),
            textBackgroundMediaID: backgroundID, textBackgroundSamples: backgroundSamples, titleSamples: titleSamples,
            textColorOverride: overrides.text, accentColorOverride: overrides.accent, barColorOverride: overrides.bar)
    }

    func previewTheme(name: String, overrides: PhotoSeriesOverrides) -> Theme {
        PhotoSeriesTheme.make(
            input(name: name, titleArtID: Self.previewTitleID,
                  backgroundID: softBackground == nil ? nil : Self.previewBackgroundID, overrides: overrides),
            id: "photo-series-preview")
    }

    /// A name for the series: the title lettered in the art, else the file
    /// name without the usual export clutter ("final", "1920x1080").
    var suggestedName: String {
        if !analysis.seriesTitle.isEmpty { return analysis.seriesTitle }
        let stem = (art.fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(\d{3,4}\s?x\s?\d{3,4}|16x9|final|title|slide|graphic|wide|copy|v\d+)\b"#,
                                  with: " ", options: [.regularExpression, .caseInsensitive])
            .split(separator: " ").joined(separator: " ")
        guard !stem.isEmpty else { return "" }
        return stem == stem.lowercased() ? stem.capitalized : stem
    }
}

/// Builds a series theme from a sermon series graphic: Claude reads the art
/// (colors, where text can go, type, the bar), or without a key or a
/// connection its palette alone is used; then the title art and the soft
/// background are rendered here and the theme assembled.
@MainActor
enum PhotoSeries {
    enum Stage {
        case reading, building
    }

    struct CouldNotRender: LocalizedError {
        var errorDescription: String? { "The art couldn't be turned into slides. Try a JPG or PNG." }
    }

    /// `variant` changes the result offline (another accent), for Regenerate.
    static func draft(from url: URL, variant: Int, stage: (Stage) -> Void) async throws -> PhotoSeriesDraft {
        stage(.reading)
        let art = try await Task.detached { try SeriesArt.load(url) }.value
        let families = await SeriesFonts.families()
        var note: String?
        var analysis: ArtAnalysis
        var readByClaude = false
        if ClaudeClient.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            analysis = await localAnalysis(art, variant: variant)
            note = "Built from the art's colors. Add a Claude key in Settings for a closer match."
        } else {
            do {
                guard let small = await Task.detached(operation: { art.jpegForClaude() }).value else { throw CouldNotRender() }
                analysis = try await ClaudeClient.analyzeArt(
                    jpeg: small.data, fileName: art.fileName, width: small.width, height: small.height, fonts: families)
                readByClaude = true
            } catch {
                try Task.checkCancellation()
                analysis = await localAnalysis(art, variant: variant)
                note = "Claude couldn't read the art, so it was built from its colors. \(Self.reason(error))"
            }
        }
        try Task.checkCancellation()
        analysis = analysis.sanitized(installedFamilies: families)

        stage(.building)
        let heading = SeriesFonts.face(analysis.headingFont, weight: analysis.headingWeight)
        let body = SeriesFonts.face(analysis.bodyFont, weight: .regular)
        let verse = analysis.scriptureItalic ? SeriesFonts.face(analysis.bodyFont, weight: .regular, italic: true) : body
        let settled = analysis
        guard let rendered = await Task.detached(operation: { render(art, settled) }).value else { throw CouldNotRender() }
        return PhotoSeriesDraft(
            art: art, analysis: rendered.analysis, titleArt: rendered.titleArt, softBackground: rendered.soft,
            headingFont: heading, bodyFont: body, verseFont: verse,
            titleSamples: rendered.titleSamples, backgroundSamples: rendered.backgroundSamples,
            readByClaude: readByClaude, note: note)
    }

    private static func reason(_ error: any Error) -> String {
        if let claude = error as? ClaudeClient.ClaudeError, case .http(let code, _) = claude, code != 401 {
            return "Claude request failed (\(code))."
        }
        return error.localizedDescription
    }

    private nonisolated static func localAnalysis(_ art: SeriesArt, variant: Int) async -> ArtAnalysis {
        await Task.detached {
            ArtAnalysis.local(swatches: SeriesPalette.extract(art.pixels(), count: 6), seriesTitle: "", variant: variant)
        }.value
    }

    private struct Rendered: @unchecked Sendable {
        var titleArt: CGImage
        var soft: CGImage?
        var titleSamples: [SeriesColor]
        var backgroundSamples: [SeriesColor]
        var analysis: ArtAnalysis
    }

    /// The title art, and the soft background dimmed a step further each
    /// time until no text color would fail on it (or it's fully dimmed).
    private nonisolated static func render(_ art: SeriesArt, _ analysis: ArtAnalysis) -> Rendered? {
        guard let title = art.titleArt(focusX: analysis.focusX, focusY: analysis.focusY) else { return nil }
        let box = PhotoSeriesTheme.titleBox(for: analysis, artWidth: Double(art.width), artHeight: Double(art.height))
        var settled = analysis
        var soft: CGImage?
        var samples: [SeriesColor] = []
        if analysis.textBackground.kind == .blurredArt {
            let wanted = SeriesColor(hex: analysis.textColor) ?? .white
            var strength = analysis.textBackground.strength
            while true {
                soft = SeriesArt.softBackground(from: title, tone: analysis.textBackground.tone,
                                                strength: strength, blur: analysis.textBackground.blur)
                samples = soft.map { SeriesArt.samples(of: $0, in: SeriesArt.textArea) } ?? []
                let best = SeriesContrast.readable(wanted, on: samples)
                if SeriesContrast.worst(best, on: samples) >= SeriesContrast.minimum || strength >= 1 { break }
                strength = min(1, strength + 0.15)
            }
            settled.textBackground.strength = strength
            guard soft != nil else { return nil }
        }
        return Rendered(titleArt: title, soft: soft, titleSamples: SeriesArt.samples(of: title, in: box),
                        backgroundSamples: samples, analysis: settled)
    }

    /// Imports the rendered art through the normal media import, then saves
    /// the theme and waits for it to land so the pickers can select it.
    static func save(_ draft: PhotoSeriesDraft, name: String, overrides: PhotoSeriesOverrides, model: AppModel) async throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let safeName = name.replacingOccurrences(of: "/", with: "-")

        func importJPEG(_ image: CGImage, _ fileName: String) async throws -> String {
            let url = folder.appendingPathComponent(fileName)
            guard let data = await Task.detached(operation: { SeriesArt.jpeg(image) }).value else { throw CouldNotRender() }
            try data.write(to: url)
            guard let id = await model.importFiles([url]).first else { throw CouldNotRender() }
            return id
        }
        let titleID = draft.analysis.titleUsesArt ? try await importJPEG(draft.titleArt, "\(safeName) Title.jpg") : nil
        var backgroundID: String?
        if let soft = draft.softBackground {
            backgroundID = try await importJPEG(soft, "\(safeName) Background.jpg")
        }
        let theme = PhotoSeriesTheme.make(draft.input(name: name, titleArtID: titleID, backgroundID: backgroundID, overrides: overrides))
        _ = try await model.createInDrive(theme).value
        return theme.id
    }
}
