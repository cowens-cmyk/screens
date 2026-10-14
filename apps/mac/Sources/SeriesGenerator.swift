import AppKit
import PresenterCore

/// Turns a series name into a finished series theme: Claude draws the
/// artwork as SVG, the app renders it to PNG and builds the theme.
@MainActor
enum SeriesGenerator {
    enum GenerateError: LocalizedError {
        case render
        var errorDescription: String? { "The series artwork couldn't be drawn. Try again." }
    }

    /// The theme already made for this series, matched by name.
    static func existingTheme(for series: String, model: AppModel) -> String? {
        let wanted = normalized(series)
        guard !wanted.isEmpty else { return nil }
        return model.entries(of: .theme).first { normalized($0.name) == wanted }?.id
    }

    /// Generates the theme, saves it, and returns its id.
    static func generate(series: String, hint: String, model: AppModel) async throws -> String {
        let fonts = Self.fontChoices
        let design = try await ClaudeClient.designSeries(name: series, hint: hint, fonts: fonts)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let safeName = series.replacingOccurrences(of: "/", with: "-")
        let backgroundURL = folder.appendingPathComponent("\(safeName) Background.png")
        let lowerThirdURL = folder.appendingPathComponent("\(safeName) Lower Third.png")
        guard let background = render(design.backgroundSVG), let lowerThird = render(design.lowerThirdSVG)
        else { throw GenerateError.render }
        try background.write(to: backgroundURL)
        try lowerThird.write(to: lowerThirdURL)

        let backgroundID = await model.importFiles([backgroundURL]).first
        let lowerThirdID = await model.importFiles([lowerThirdURL]).first
        let style = SermonSeriesStyle(
            name: series,
            backgroundMediaID: backgroundID,
            lowerThirdMediaID: lowerThirdID,
            font: SermonSeriesSheet.postScript(design.bodyFont, bold: false),
            boldFont: SermonSeriesSheet.postScript(design.headingFont, bold: true),
            textColor: SeriesDesign.color(design.textColor, fallback: "#FFFFFFFF"),
            accentColor: SeriesDesign.color(design.accentColor, fallback: "#FFB21EFF"),
            lowerThirdTextColor: SeriesDesign.color(design.lowerThirdTextColor, fallback: "#FFFFFFFF"),
            lowerThirdAccentColor: SeriesDesign.color(design.lowerThirdAccentColor, fallback: "#FFB21EFF"),
            headingCaps: design.headingAllCaps)
        let theme = SermonSeriesTheme.make(style)
        // Wait for the save so the theme is in the library (and the
        // pickers) before anything selects it.
        _ = try await model.createInDrive(theme).value
        return theme.id
    }

    /// Renders an SVG at 1920×1080, keeping transparency.
    static func render(_ svg: String) -> Data? {
        guard let image = NSImage(data: Data(SeriesDesign.sanitize(svg).utf8)),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 1080, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Display families that ship with macOS and read well on screen.
    private static var fontChoices: [String] {
        let preferred = ["Helvetica Neue", "Avenir Next", "Avenir Next Condensed", "Futura", "Gill Sans",
                         "Optima", "Didot", "Baskerville", "Georgia", "Palatino", "Hoefler Text",
                         "Rockwell", "Copperplate", "Montserrat", "DIN Alternate", "DIN Condensed",
                         "Impact", "Bebas Neue", "SF Pro Display", "Charter", "Seravek", "Big Caslon"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let choices = preferred.filter(installed.contains)
        return choices.isEmpty ? ["Helvetica Neue"] : choices
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
