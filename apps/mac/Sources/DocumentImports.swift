import AppKit
import Foundation
import PDFKit
import PresenterCore

/// PDFs and Keynote decks. A PDF that reads as a chord chart becomes a song —
/// lyrics, sections, chords (shown as Nashville numbers on the worship stage
/// layout) and key; any other PDF becomes one full-screen slide per page.
/// Keynote decks are exported to PowerPoint by Keynote itself and then
/// imported like any .pptx, so text stays editable.
extension AppModel {

    static let documentImportExtensions: Set<String> = ["pdf", "key"]

    /// Splits off the files `importFiles` doesn't handle and imports them;
    /// returns the remaining URLs for the media importer.
    func importDocuments(from urls: [URL]) async -> (handled: [String], rest: [URL]) {
        var handled: [String] = []
        var rest: [URL] = []
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "pdf":
                if let id = await importPDF(url) { handled.append(id) }
            case "key":
                handled += await importKeynote(url)
            default:
                rest.append(url)
            }
        }
        return (handled, rest)
    }

    /// True when the PDF's text has chords over lyrics.
    nonisolated static func chordChartSource(fromPDF url: URL) -> String? {
        guard let source = ChordChartImport.chordPro(fromPDF: url) else { return nil }
        let chords = source.components(separatedBy: "[").count - 1
        return chords >= 4 ? source : nil
    }

    func importPDF(_ url: URL) async -> String? {
        let source = await Task.detached { Self.chordChartSource(fromPDF: url) }.value
        if let source {
            return importChordChart(source: source, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        }
        return await importPDFSlides(url)
    }

    @discardableResult
    func importChordChart(source: String, fallbackTitle: String) -> String {
        var presentation = LyricTextImporter.makePresentation(
            LyricCleanup.clean(source, removePunctuation: LyricImportSettings.removePunctuation),
            fallbackTitle: fallbackTitle, themeId: slideBuilding.lyricsImportThemeId ?? "")
        presentation.presentationKind = .song
        presentation.category = PresentationTypes.worship
        presentation.folder = newPlacement.folder(for: .presentation)
        createInDrive(presentation)
        lastImportSummary = "Imported chord chart \"\(presentation.name)\" (\(presentation.slides.count) slides)"
        return presentation.id
    }

    /// Replaces a song's lyrics, sections, arrangement, chords and key with
    /// a chord chart's, keeping its name, theme and backgrounds.
    func applyChordChart(_ url: URL, to presentationID: String) async -> Bool {
        let source: String?
        if url.pathExtension.lowercased() == "pdf" {
            source = await Task.detached { ChordChartImport.chordPro(fromPDF: url) }.value
        } else {
            source = (try? String(contentsOf: url, encoding: .utf8)).map {
                LyricTextImporter.detectFormat($0) == .chordPro ? $0 : ChordChartImport.chordPro(fromChart: $0)
            }
        }
        guard let source else { return false }
        let chart = LyricTextImporter.makePresentation(
            LyricCleanup.clean(source, removePunctuation: LyricImportSettings.removePunctuation), fallbackTitle: nil)
        updatePresentation(presentationID) { presentation in
            presentation.slides = chart.slides
            presentation.sections = chart.sections
            presentation.arrangements = chart.arrangements
            presentation.defaultArrangementId = chart.defaultArrangementId
            presentation.reflowSource = chart.reflowSource
            presentation.chordProSource = chart.chordProSource
            presentation.musicKey = chart.musicKey ?? presentation.musicKey
            presentation.ccli = chart.ccli ?? presentation.ccli
            presentation.presentationKind = .song
        }
        lastImportSummary = "Chord chart applied (\(chart.slides.count) slides)"
        return true
    }

    /// One full-screen slide per PDF page.
    func importPDFSlides(_ url: URL) async -> String? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("screens-pdf-\(UUID().uuidString)", isDirectory: true)
        let pages: [URL] = await Task.detached {
            guard let document = PDFDocument(url: url) else { return [] }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (0..<document.pageCount).compactMap { index -> URL? in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 1920 / max(bounds.width, 1)
                let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return nil }
                let file = folder.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent) \(index + 1).png")
                return (try? png.write(to: file)) == nil ? nil : file
            }
        }.value
        guard !pages.isEmpty else { return nil }
        let mediaIDs = await importFiles(pages)
        let slides = mediaIDs.compactMap { id -> Slide? in
            guard let item = media(id) else { return nil }
            var slide = Slide(id: UUID().uuidString, name: item.name, objects: [])
            slide.background = .droppedAsNewSlide(for: item)
            return slide
        }
        guard !slides.isEmpty else { return nil }
        let presentation = Presentation(
            id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent,
            presentationKind: .deck, themeId: "", folder: newPlacement.folder(for: .presentation),
            slides: slides)
        createInDrive(presentation)
        lastImportSummary = "Imported \"\(presentation.name)\" (\(slides.count) pages)"
        try? FileManager.default.removeItem(at: folder)
        return presentation.id
    }

    /// Asks Keynote to export the deck as PowerPoint, then imports that.
    func importKeynote(_ url: URL) async -> [String] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).pptx")
        try? FileManager.default.removeItem(at: output)
        let script = """
        tell application "Keynote"
            set theDoc to open POSIX file "\(url.path.replacingOccurrences(of: "\"", with: "\\\""))"
            export theDoc to POSIX file "\(output.path.replacingOccurrences(of: "\"", with: "\\\""))" as Microsoft PowerPoint
            close theDoc saving no
        end tell
        """
        let error: String? = await Task.detached {
            var info: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&info)
            return info.map { "\($0[NSAppleScript.errorMessage] ?? $0)" }
        }.value
        guard error == nil, FileManager.default.fileExists(atPath: output.path) else {
            lastImportSummary = "Keynote export failed — Keynote must be installed, and Screens needs permission to control it. \(error ?? "")"
            return []
        }
        let summaries = await importPowerPoint(urls: [output])
        try? FileManager.default.removeItem(at: output)
        return summaries.compactMap(\.presentationID)
    }
}
