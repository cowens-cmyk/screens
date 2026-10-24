import AppKit
import PresenterCore

/// Reads a Claude Design series download (a ZIP, a folder or loose files):
/// the background, the lower third and screens-theme.json. SVG artwork is
/// drawn to PNG first. PhotoSeries turns what's found into the designs.
@MainActor
enum ClaudeDesignImport {
    struct Result {
        var series: String?
        var background: URL?
        var lowerThird: URL?
        /// PostScript names of installed faces.
        var headingFont: String?
        var bodyFont: String?
        var scriptureFont: String?
        var headingCaps: Bool?
        var textColor: String?
        var accentColor: String?
        var lowerThirdTextColor: String?
        var lowerThirdAccentColor: String?
        /// Fonts the export asked for that aren't on this Mac.
        var missingFonts: [String] = []
        /// The download's screens-theme.json, when it has one.
        var export: SeriesExport?
    }

    enum ImportError: LocalizedError {
        case noImages
        case noBackground
        var errorDescription: String? {
            switch self {
            case .noImages: "No images found in that download."
            case .noBackground: "No background image found in that download."
            }
        }
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "svg"]

    /// A ZIP, a folder, SVG artwork, the JSON, or several files at once.
    static func isDownload(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if urls.count > 1 { return urls.contains { imageExtensions.contains($0.pathExtension.lowercased()) } }
        let url = urls[0]
        if ["zip", "svg", "json"].contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func read(_ urls: [URL]) async throws -> Result {
        // Unzipping and walking folders waits on disk, so it's done off
        // the main thread.
        var files = try await Task.detached { try urls.flatMap(expand) }.value
        files = files.map(rasterized)
        let images = files.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { throw ImportError.noImages }
        let export = files.first { $0.lastPathComponent.lowercased() == SeriesExport.fileName }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? SeriesExport.decode($0) }

        func named(_ name: String?) -> URL? {
            guard let name = name?.lowercased() else { return nil }
            let leaf = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            return images.first { ($0.lastPathComponent.lowercased() as NSString).deletingPathExtension == leaf }
        }
        var result = Result()
        result.export = export
        // Named in the JSON first; otherwise the image that's see-through
        // at the top is the lower third and an opaque one is the background.
        result.lowerThird = named(export?.lowerThird) ?? images.first(where: isTransparentAtTop)
        result.background = named(export?.background)
            ?? images.first { $0 != result.lowerThird && !isTransparentAtTop($0) }

        guard let export else { return result }
        result.series = export.series.trimmingCharacters(in: .whitespaces).isEmpty ? nil : export.series
        for (list, slot) in [(export.headingFont, \Result.headingFont), (export.bodyFont, \.bodyFont), (export.scriptureFont, \.scriptureFont)] {
            guard let list, !list.isEmpty else { continue }
            if let found = list.lazy.compactMap(postScriptName).first {
                result[keyPath: slot] = found
            }
            if postScriptName(list[0]) == nil { result.missingFonts.append(list[0]) }
        }
        result.headingCaps = export.headingAllCaps
        result.textColor = export.textColor.map { SeriesDesign.color($0, fallback: "#FFFFFFFF") }
        result.accentColor = export.accentColor.map { SeriesDesign.color($0, fallback: "#FFB21EFF") }
        result.lowerThirdTextColor = export.lowerThirdTextColor.map { SeriesDesign.color($0, fallback: "#FFFFFFFF") }
        result.lowerThirdAccentColor = export.lowerThirdAccentColor.map { SeriesDesign.color($0, fallback: "#FFB21EFF") }
        return result
    }

    /// A ZIP is unpacked to a temporary folder; folders are walked.
    private nonisolated static func expand(_ url: URL) throws -> [URL] {
        if url.pathExtension.lowercased() == "zip" {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-design-\(UUID().uuidString)", isDirectory: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, folder.path]
            try ditto.run()
            ditto.waitUntilExit()
            return try expand(folder)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).filter { !$0.path.contains("__MACOSX") }
    }

    /// SVG artwork drawn to a PNG beside a temporary copy, keeping its
    /// transparency (the lower third needs it). Anything else is unchanged.
    private static func rasterized(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "svg", let svg = try? String(contentsOf: url, encoding: .utf8),
              let png = SeriesGenerator.render(svg)
        else { return url }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-design-svg-\(UUID().uuidString)", isDirectory: true)
        let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: out)
            return out
        } catch {
            return url
        }
    }

    private static func isTransparentAtTop(_ url: URL) -> Bool {
        guard let rep = NSImage(contentsOf: url)?.representations.first as? NSBitmapImageRep ??
                (NSImage(contentsOf: url)?.tiffRepresentation).flatMap(NSBitmapImageRep.init(data:)),
              rep.hasAlpha, rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return false }
        let samples = [(0.5, 0.1), (0.2, 0.3), (0.8, 0.3)]
        return samples.allSatisfy { fx, fy in
            let color = rep.colorAt(x: Int(Double(rep.pixelsWide) * fx), y: Int(Double(rep.pixelsHigh) * fy))
            return (color?.alphaComponent ?? 1) < 0.05
        }
    }

    /// "Gotham Black", "Gotham-Black" or "Avenir Next Heavy" to the
    /// installed face's PostScript name, or nil when it isn't installed.
    static func postScriptName(_ requested: String) -> String? {
        let wanted = requested.trimmingCharacters(in: .whitespaces)
        if let font = NSFont(name: wanted, size: 12) { return font.fontName }
        let manager = NSFontManager.shared
        let lower = wanted.lowercased()
        let family = manager.availableFontFamilies
            .filter { lower.hasPrefix($0.lowercased()) }
            .max { $0.count < $1.count }
        guard let family else { return nil }
        let style = wanted.dropFirst(family.count).trimmingCharacters(in: .whitespaces).lowercased()
        let members = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> (String, String)? in
            guard let name = member.first as? String, let face = member.dropFirst().first as? String else { return nil }
            return (name, face.lowercased())
        }
        let target = style.isEmpty ? "regular" : style
        return members.first { $0.1 == target }?.0
            ?? members.first { $0.1.replacingOccurrences(of: " ", with: "") == target.replacingOccurrences(of: " ", with: "") }?.0
            ?? (style.isEmpty ? members.first?.0 : nil)
    }
}
