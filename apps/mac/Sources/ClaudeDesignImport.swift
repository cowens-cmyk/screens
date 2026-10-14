import AppKit
import PresenterCore

/// Reads a Claude Design series download (a ZIP, a folder or loose files):
/// the background, the lower third and screens-theme.json.
enum ClaudeDesignImport {
    struct Result {
        var series: String?
        var background: URL?
        var lowerThird: URL?
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
    }

    enum ImportError: LocalizedError {
        case noImages
        var errorDescription: String? { "No images found in that download." }
    }

    static func read(_ urls: [URL]) throws -> Result {
        let files = try urls.flatMap(expand)
        let images = files.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { throw ImportError.noImages }
        let export = files.first { $0.lastPathComponent.lowercased() == SeriesExport.fileName }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? SeriesExport.decode($0) }

        func named(_ name: String?) -> URL? {
            guard let name = name?.lowercased() else { return nil }
            let leaf = (name as NSString).lastPathComponent
            return images.first { $0.lastPathComponent.lowercased() == leaf }
        }
        var result = Result()
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
    private static func expand(_ url: URL) throws -> [URL] {
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
