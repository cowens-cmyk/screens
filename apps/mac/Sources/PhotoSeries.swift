import AppKit
import PresenterCore
import UniformTypeIdentifiers

/// Staff's own picks from Edit Colors & Fonts. Nil keeps what was chosen
/// automatically.
struct PhotoSeriesOverrides: Equatable {
    var text: SeriesColor?
    var accent: SeriesColor?
    var bar: SeriesColor?
    /// PostScript names of the faces.
    var headingFont: String?
    var bodyFont: String?
    var verseFont: String?
    var headingCaps: Bool?
}

/// Designs made from art, read and rendered but not yet in the library:
/// the preview shows them, Done saves them.
struct PhotoSeriesDraft: @unchecked Sendable {
    enum Source {
        /// A picture: Claude (or its palette) decides everything.
        case art
        /// A Claude Design download, whose own colors and fonts are used.
        case claudeDesign
    }

    var source: Source
    var kind: PhotoSeriesTheme.Kind
    /// The dropped file or download's name, for naming the theme.
    var sourceName: String
    var art: SeriesArt
    /// Sanitized, with the dimming strength the contrast check settled on.
    var analysis: ArtAnalysis
    var titleArt: CGImage
    /// The text slides' background made from the art, when the analysis
    /// chose that: blurred for a picture, left sharp for a designed one.
    var softBackground: CGImage?
    /// A download's own transparent lower third.
    var lowerThird: CGImage?
    var lowerThirdSamples: [SeriesColor]
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
    static let previewLowerThirdID = "photo-series-preview-lower-third"

    var previewImages: [String: CGImage] {
        var images = [Self.previewTitleID: titleArt]
        if let softBackground { images[Self.previewBackgroundID] = softBackground }
        if let lowerThird { images[Self.previewLowerThirdID] = lowerThird }
        return images
    }

    /// Another read gives a different result only for a picture: a
    /// download's choices are its own.
    var canTryAgain: Bool { source == .art }

    func input(name: String, titleArtID: String?, backgroundID: String?, lowerThirdID: String?,
               overrides: PhotoSeriesOverrides) -> PhotoSeriesTheme.Input {
        var analysis = analysis
        if let caps = overrides.headingCaps { analysis.headingAllCaps = caps }
        return PhotoSeriesTheme.Input(
            name: name, analysis: analysis, headingFont: overrides.headingFont ?? headingFont,
            bodyFont: overrides.bodyFont ?? bodyFont, verseFont: overrides.verseFont ?? verseFont,
            titleArtMediaID: titleArtID, artWidth: Double(art.width), artHeight: Double(art.height),
            textBackgroundMediaID: backgroundID, textBackgroundSamples: backgroundSamples, titleSamples: titleSamples,
            textColorOverride: overrides.text, accentColorOverride: overrides.accent, barColorOverride: overrides.bar,
            kind: kind, lowerThirdMediaID: lowerThird == nil ? nil : lowerThirdID, lowerThirdSamples: lowerThirdSamples)
    }

    func previewTheme(name: String, overrides: PhotoSeriesOverrides) -> Theme {
        PhotoSeriesTheme.make(
            input(name: name, titleArtID: Self.previewTitleID,
                  backgroundID: softBackground == nil ? nil : Self.previewBackgroundID,
                  lowerThirdID: Self.previewLowerThirdID, overrides: overrides),
            id: "photo-series-preview")
    }

    /// A name: the title lettered in the art (or the download's series),
    /// else the file name without the usual export clutter ("final",
    /// "1920x1080"), else a plain stand-in, so Done never waits on typing.
    var suggestedName: String {
        if !analysis.seriesTitle.isEmpty { return analysis.seriesTitle }
        let stem = (sourceName as NSString).deletingPathExtension
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(\d{3,4}\s?x\s?\d{3,4}|16x9|final|title|slide|graphic|wide|copy|v\d+|download|claude design)\b"#,
                                  with: " ", options: [.regularExpression, .caseInsensitive])
            .split(separator: " ").joined(separator: " ")
        if !stem.isEmpty { return stem == stem.lowercased() ? stem.capitalized : stem }
        return kind == .general ? "New Theme" : "New Series"
    }
}

/// Builds designs from art in one step. A picture: Claude reads it (colors,
/// where text can go, type, the bar), or without a key or a connection its
/// palette alone is used. A Claude Design download: its own colors and
/// fonts over its own background and lower third. Either way the title
/// art and text background are rendered here, every text color is checked
/// against what it sits on, and the theme is assembled.
@MainActor
enum PhotoSeries {
    enum Stage {
        case reading, building
    }

    struct CouldNotRender: LocalizedError {
        var errorDescription: String? { "The art couldn't be turned into slides. Try a JPG or PNG." }
    }

    /// Kinds of file the drop zone and Choose File take.
    static let fileTypes = SeriesArt.types + [.zip, .folder, .svg, .json]

    /// A picture (a PDF too), or something that looks like a Claude Design
    /// download: what the series sheet's own drop zone and Choose File
    /// take, where nothing else could be meant.
    static func accepts(_ urls: [URL]) -> Bool {
        if urls.count == 1, let url = urls.first, SeriesArt.accepts(url) { return true }
        return ClaudeDesignImport.isDownload(urls)
    }

    /// Dropped where art is clearly wanted but not on the sheet itself (the
    /// Message & Series sheet, the Themes library): the same, less PDFs,
    /// which are as likely to be the sermon notes as the series art.
    static func acceptsDropped(_ urls: [URL]) -> Bool {
        !urls.contains { DesignDownload.isPDF($0.lastPathComponent) } && accepts(urls)
    }

    /// Dropped on a plan's list, where files land for many reasons: one
    /// picture or one ZIP, and the sheet asks before reading it.
    static func acceptsOnPlan(_ urls: [URL]) -> Bool {
        DesignDownload.acceptsOnPlan(urls.map(\.lastPathComponent))
    }

    /// Anything but one picture is read as a download.
    static func isDownload(_ urls: [URL]) -> Bool {
        !(urls.count == 1 && urls.first.map(SeriesArt.accepts) == true)
    }

    /// `variant` changes the result offline (another accent), for Try Again.
    static func draft(from files: [URL], kind: PhotoSeriesTheme.Kind, variant: Int,
                      stage: (Stage) -> Void) async throws -> PhotoSeriesDraft {
        stage(.reading)
        guard let first = files.first else { throw CouldNotRender() }
        let families = await SeriesFonts.families()

        guard isDownload(files) else {
            let art = try await Task.detached { try SeriesArt.load(first) }.value
            let read = await analyze(art, variant: variant, families: families)
            try Task.checkCancellation()
            let analysis = read.analysis.sanitized(installedFamilies: families)
            let heading = SeriesFonts.face(analysis.headingFont, weight: analysis.headingWeight)
            let body = SeriesFonts.face(analysis.bodyFont, weight: .regular)
            let verse = analysis.scriptureItalic ? SeriesFonts.face(analysis.bodyFont, weight: .regular, italic: true) : body
            stage(.building)
            return try await build(
                art, analysis, source: .art, kind: kind, sourceName: first.lastPathComponent, lowerThird: nil,
                fonts: (heading, body, verse), readByClaude: read.byClaude, note: read.note)
        }

        let found = try await ClaudeDesignImport.read(files)
        // Everything needed is in memory once the two images are loaded,
        // so the unpacked download goes however the build ends.
        defer { found.cleanUp() }
        guard let backgroundURL = found.background else { throw ClaudeDesignImport.ImportError.noBackground }
        let art = try await Task.detached { try SeriesArt.load(backgroundURL) }.value
        let lowerThirdURL = found.lowerThird
        let lowerThird = await Task.detached { () -> CGImage? in
            guard let loaded = lowerThirdURL.flatMap({ try? SeriesArt.load($0) }) else { return nil }
            return SeriesArt.lowerThirdCanvas(loaded.image)
        }.value
        let name = files.count == 1 ? first.lastPathComponent : first.deletingLastPathComponent().lastPathComponent
        var notes: [String] = []
        if !found.missingFonts.isEmpty {
            notes.append("Not installed, so a similar font is used: \(found.missingFonts.joined(separator: ", ")).")
        }
        if found.lowerThird == nil { notes.append("No lower third in the download, so one was made to match.") }

        guard let export = found.export else {
            // Art without screens-theme.json: read like any picture.
            let read = await analyze(art, variant: variant, families: families)
            try Task.checkCancellation()
            let analysis = read.analysis.sanitized(installedFamilies: families)
            let body = SeriesFonts.face(analysis.bodyFont, weight: .regular)
            stage(.building)
            return try await build(
                art, analysis, source: .art, kind: kind, sourceName: name, lowerThird: lowerThird,
                fonts: (SeriesFonts.face(analysis.headingFont, weight: analysis.headingWeight), body,
                        analysis.scriptureItalic ? SeriesFonts.face(analysis.bodyFont, weight: .regular, italic: true) : body),
                readByClaude: read.byClaude, note: ([read.note].compactMap { $0 } + notes).joined(separator: " ").nilIfEmpty)
        }
        let swatches = await Task.detached { SeriesPalette.extract(art.pixels(), count: 6) }.value
        let analysis = ArtAnalysis.designed(export, swatches: swatches).sanitized(installedFamilies: families)
        let heading = found.headingFont ?? SeriesFonts.face(analysis.headingFont, weight: .bold)
        let body = found.bodyFont ?? SeriesFonts.face(analysis.bodyFont, weight: .regular)
        stage(.building)
        return try await build(
            art, analysis, source: .claudeDesign, kind: kind, sourceName: name, lowerThird: lowerThird,
            fonts: (heading, body, found.scriptureFont ?? body), readByClaude: false,
            note: notes.joined(separator: " ").nilIfEmpty)
    }

    /// Claude's read of a picture, or its palette's when there's no key or
    /// Claude can't be reached.
    private static func analyze(_ art: SeriesArt, variant: Int, families: [String]) async
        -> (analysis: ArtAnalysis, byClaude: Bool, note: String?) {
        if ClaudeClient.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (await localAnalysis(art, variant: variant),
                    false, "Built from the art's colors. Add a Claude key in Settings for a closer match.")
        }
        // The palette's read is made first: it fills whatever Claude's
        // answer leaves out, and stands in for all of it if there's none.
        let local = await localAnalysis(art, variant: variant)
        do {
            guard let small = await Task.detached(operation: { art.jpegForClaude() }).value else { throw CouldNotRender() }
            let analysis = try await ClaudeClient.analyzeArt(
                jpeg: small.data, fileName: art.fileName, width: small.width, height: small.height, fonts: families,
                fallback: local)
            return (analysis, true, nil)
        } catch {
            return (local, false, "Claude couldn't read the art, so it was built from its colors. \(Self.reason(error))")
        }
    }

    private static func build(
        _ art: SeriesArt, _ analysis: ArtAnalysis, source: PhotoSeriesDraft.Source, kind: PhotoSeriesTheme.Kind,
        sourceName: String, lowerThird: CGImage?, fonts: (heading: String, body: String, verse: String),
        readByClaude: Bool, note: String?
    ) async throws -> PhotoSeriesDraft {
        let sharp = source == .claudeDesign
        guard let rendered = await Task.detached(operation: { render(art, analysis, sharp: sharp) }).value
        else { throw CouldNotRender() }
        let barSamples = await Task.detached(operation: { () -> [SeriesColor] in
            guard let lowerThird else { return [] }
            return PhotoSeriesTheme.barSamples(SeriesArt.barPixels(of: lowerThird))
        }).value
        try Task.checkCancellation()
        return PhotoSeriesDraft(
            source: source, kind: kind, sourceName: sourceName, art: art, analysis: rendered.analysis,
            titleArt: rendered.titleArt, softBackground: rendered.soft, lowerThird: lowerThird,
            lowerThirdSamples: barSamples, headingFont: fonts.heading, bodyFont: fonts.body, verseFont: fonts.verse,
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

    /// The title art, and the text background dimmed a step further each
    /// time until no text color would fail on it (or it's fully dimmed).
    /// A designed background starts undimmed and is never blurred. Whatever
    /// is left over, PhotoSeriesTheme.colors fixes in the text color.
    private nonisolated static func render(_ art: SeriesArt, _ analysis: ArtAnalysis, sharp: Bool) -> Rendered? {
        guard let title = art.titleArt(focusX: analysis.focusX, focusY: analysis.focusY) else { return nil }
        let box = PhotoSeriesTheme.titleBox(for: analysis, artWidth: Double(art.width), artHeight: Double(art.height))
        var settled = analysis
        var soft: CGImage?
        var samples: [SeriesColor] = []
        if analysis.textBackground.kind == .blurredArt {
            let wanted = SeriesColor(hex: analysis.textColor) ?? .white
            var strength = analysis.textBackground.strength
            while true {
                soft = sharp
                    ? SeriesArt.veiled(title, tone: analysis.textBackground.tone, strength: strength)
                    : SeriesArt.softBackground(from: title, tone: analysis.textBackground.tone,
                                               strength: strength, blur: analysis.textBackground.blur)
                samples = soft.map { SeriesArt.samples(of: $0, in: SeriesArt.textArea) } ?? []
                // A designed background is dimmed until the download's own
                // text color reads; a picture's may move its text color first.
                let best = sharp ? wanted : SeriesContrast.readable(wanted, on: samples)
                if SeriesContrast.worst(best, on: samples) >= SeriesContrast.minimum || strength >= 1 { break }
                strength = min(1, strength + 0.15)
            }
            settled.textBackground.strength = strength
            guard soft != nil else { return nil }
        }
        return Rendered(titleArt: title, soft: soft, titleSamples: SeriesArt.samples(of: title, in: box),
                        backgroundSamples: samples, analysis: settled)
    }

    /// The media one draft's save has imported. When the theme then fails to
    /// save, Done again uses these instead of importing the same art twice.
    @MainActor
    final class ImportedMedia {
        var title: String?
        var background: String?
        var lowerThird: String?
    }

    /// Imports the rendered art through the normal media import, then saves
    /// the theme and waits for it to land so the pickers can select it.
    /// `imported` belongs to this draft and is kept across tries.
    static func save(_ draft: PhotoSeriesDraft, name: String, overrides: PhotoSeriesOverrides, model: AppModel,
                     imported: ImportedMedia) async throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let safeName = name.replacingOccurrences(of: "/", with: "-")

        func importImage(_ image: CGImage, _ fileName: String, png: Bool = false,
                         as slot: ReferenceWritableKeyPath<ImportedMedia, String?>) async throws -> String {
            if let id = imported[keyPath: slot] { return id }
            let url = folder.appendingPathComponent(fileName)
            guard let data = await Task.detached(operation: { png ? SeriesArt.png(image) : SeriesArt.jpeg(image) }).value
            else { throw CouldNotRender() }
            try data.write(to: url)
            guard let id = await model.importFiles([url]).first else { throw CouldNotRender() }
            imported[keyPath: slot] = id
            return id
        }
        let titleID = draft.analysis.titleUsesArt
            ? try await importImage(draft.titleArt, "\(safeName) Title.jpg", as: \.title) : nil
        var backgroundID: String?
        if let soft = draft.softBackground {
            // A designed background no text needed dimmed is the title art
            // itself; one copy in the library serves both.
            if soft === draft.titleArt, let titleID {
                backgroundID = titleID
            } else {
                backgroundID = try await importImage(soft, "\(safeName) Background.jpg", as: \.background)
            }
        }
        var lowerThirdID: String?
        if let lowerThird = draft.lowerThird {
            lowerThirdID = try await importImage(lowerThird, "\(safeName) Lower Third.png", png: true, as: \.lowerThird)
        }
        let theme = PhotoSeriesTheme.make(draft.input(
            name: name, titleArtID: titleID, backgroundID: backgroundID, lowerThirdID: lowerThirdID, overrides: overrides))
        _ = try await model.createInDrive(theme).value
        return theme.id
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
