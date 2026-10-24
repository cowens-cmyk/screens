import AppKit
import ImageIO
import PresenterCore
import UniformTypeIdentifiers

/// Reads a Claude Design series download (a ZIP, a folder or loose files):
/// the background, the lower third and screens-theme.json. SVG artwork is
/// drawn to PNG first. PhotoSeries turns what's found into the designs.
@MainActor
enum ClaudeDesignImport {
    struct Result: Sendable {
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
        /// Where the ZIP was unpacked and SVGs drawn. The background and
        /// lower third may live here, so it's removed (cleanUp) once
        /// they've been read.
        var scratch: URL?

        func cleanUp() {
            guard let scratch else { return }
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    enum ImportError: LocalizedError {
        case noImages
        case noBackground
        case drewNothing(String)
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noImages: "No images found in that download."
            case .noBackground: "No background image found in that download."
            case .drewNothing(let name): "This SVG drew nothing: \(name)."
            case .unreadable(let name): "Couldn't read \(name)."
            }
        }
    }

    private nonisolated static let imageExtensions = ["png", "jpg", "jpeg", "heic", "svg"]
    private nonisolated static let rasterExtensions = ["png", "jpg", "jpeg", "heic"]

    /// A ZIP, a folder, SVG artwork, the JSON, or several files at once.
    static func isDownload(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if urls.count > 1 { return urls.contains { imageExtensions.contains($0.pathExtension.lowercased()) } }
        let url = urls[0]
        if ["zip", "svg", "json"].contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The files read and sorted, before fonts are looked up.
    private struct Found: Sendable {
        var background: URL?
        var lowerThird: URL?
        var export: SeriesExport?
        var scratch: URL
    }

    /// Unpacking, walking folders, drawing SVGs and looking at every image
    /// wait on disk and take real work, so all of it is done off the main
    /// thread; only the font lookup comes back to it. The caller removes
    /// the scratch folder with Result.cleanUp once it has what it needs;
    /// if reading fails it's removed here.
    static func read(_ urls: [URL]) async throws -> Result {
        let found = try await Task.detached(priority: .userInitiated) { try gather(urls) }.value
        var result = Result()
        result.scratch = found.scratch
        result.export = found.export
        result.background = found.background
        result.lowerThird = found.lowerThird

        guard let export = found.export else { return result }
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

    private nonisolated static func gather(_ urls: [URL]) throws -> Found {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-design-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var tally = DesignDownload.Tally()
            var files: [URL] = []
            for (index, url) in urls.enumerated() {
                files += try expand(url, scratch: scratch, index: index, tally: &tally)
            }
            var images: [URL] = []
            // An SVG that won't draw is an error only when it's needed: the
            // JSON names it, or there's no other artwork.
            var failed: [(leaf: String, error: any Error)] = []
            for file in files {
                let ext = file.pathExtension.lowercased()
                if ext == "svg" {
                    do {
                        images.append(try rasterized(file, into: scratch))
                    } catch {
                        failed.append((file.deletingPathExtension().lastPathComponent.lowercased(), error))
                    }
                } else if rasterExtensions.contains(ext) {
                    images.append(file)
                }
            }
            guard !images.isEmpty else { throw failed.first?.error ?? ImportError.noImages }
            let export = files.first { $0.lastPathComponent.lowercased() == SeriesExport.fileName }
                .flatMap { url -> Data? in
                    // The JSON is a few hundred bytes; anything big isn't it.
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return size <= 1_000_000 ? try? Data(contentsOf: url) : nil
                }
                .flatMap { try? SeriesExport.decode($0) }

            func leaf(_ name: String) -> String {
                ((name.lowercased() as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            func named(_ name: String?) -> URL? {
                guard let name else { return nil }
                return images.first { leaf($0.lastPathComponent) == leaf(name) }
            }
            for wanted in [export?.background, export?.lowerThird].compactMap({ $0 }) where named(wanted) == nil {
                if let failure = failed.first(where: { $0.leaf == leaf(wanted) }) { throw failure.error }
            }
            // Named in the JSON first; otherwise an image that's see-through
            // at the top, or a strip far wider than a screen, is the lower
            // third, and an opaque one is the background. Each is looked at
            // from a small thumbnail, never decoded at full size.
            var looks: [URL: Look] = [:]
            for image in images where looks[image] == nil { looks[image] = look(image) }
            let lowerThird = named(export?.lowerThird) ?? images.first { looks[$0]?.isLowerThird == true }
            let background = named(export?.background)
                ?? images.first { $0 != lowerThird && looks[$0]?.isLowerThird == false }
            return Found(background: background, lowerThird: lowerThird, export: export, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    // MARK: Files

    /// A ZIP is unpacked into the scratch folder and walked; a folder is
    /// walked; a file is itself. Every file counts toward the download's
    /// limits.
    private nonisolated static func expand(_ url: URL, scratch: URL, index: Int,
                                           tally: inout DesignDownload.Tally) throws -> [URL] {
        if url.pathExtension.lowercased() == "zip" {
            let folder = scratch.appendingPathComponent("zip-\(index)", isDirectory: true)
            try unzip(url, to: folder)
            return try walk(folder, tally: &tally)
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return try walk(url, tally: &tally) }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try tally.add(bytes: Int64(values?.fileSize ?? 0), depth: 0)
        return [url]
    }

    /// Checked before anything is written: the ZIP's size, its entries'
    /// names (nothing absolute or climbing out with "..") and count, and
    /// its uncompressed total. Then ditto unpacks it, and must succeed.
    private nonisolated static func unzip(_ zip: URL, to folder: URL) throws {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= DesignDownload.maxBytes else { throw DesignDownload.LimitError.tooLarge }
        let (namesStatus, names) = try run("/usr/bin/unzip", ["-Z1", zip.path])
        guard namesStatus == 0 else { throw DesignDownload.LimitError.unreadableZip }
        try DesignDownload.checkEntries(names)
        let (listStatus, listing) = try run("/usr/bin/unzip", ["-l", zip.path])
        guard listStatus == 0, let total = DesignDownload.listedSize(listing) else {
            throw DesignDownload.LimitError.unreadableZip
        }
        guard total <= DesignDownload.maxBytes else { throw DesignDownload.LimitError.tooLarge }
        let (status, _) = try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard status == 0 else { throw DesignDownload.LimitError.unreadableZip }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting, so a long listing can't fill the pipe and
        // stall the tool.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// The folder's files, no deeper than the limit. Links are skipped and
    /// so is anything that resolves outside the folder, so a download
    /// can't point the import at other files on the Mac.
    private nonisolated static func walk(_ folder: URL, tally: inout DesignDownload.Tally) throws -> [URL] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [URL] = []
        while let file = walker.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if file.lastPathComponent == "__MACOSX" || values?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard DesignDownload.isInside(resolved, root: root) else {
                walker.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                // Its files would be deeper than the limit.
                if walker.level > DesignDownload.maxDepth { throw DesignDownload.LimitError.tooDeep }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            try tally.add(bytes: Int64(values?.fileSize ?? 0), depth: walker.level - 1)
            files.append(file)
        }
        return files
    }

    // MARK: SVG

    /// SVG artwork drawn to a PNG in the scratch folder at its own
    /// proportions (its viewBox), keeping its transparency: the background
    /// is cropped to the screen later like any picture, and the lower third
    /// is fitted to the bottom of the frame (SeriesArt.lowerThirdCanvas).
    /// Pictures embedded in the SVG are kept; anything it links to outside
    /// itself is not. An SVG that draws nothing is an error, not a blank
    /// slide; one that only wraps an embedded picture the renderer can't
    /// draw gives that picture instead.
    private nonisolated static func rasterized(_ url: URL, into scratch: URL) throws -> URL {
        let name = url.lastPathComponent
        guard let svg = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable(name) }
        let clean = SeriesDesign.sanitize(svg, keepEmbeddedImages: true)
        let folder = scratch.appendingPathComponent("svg", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")

        if let image = NSImage(data: Data(clean.utf8)) {
            let shape = SeriesDesign.svgSize(clean)
                ?? (image.size.width > 0 && image.size.height > 0 ? (image.size.width, image.size.height) : (1920, 1080))
            let size = ArtCrop.renderSize(width: shape.width, height: shape.height)
            if let drawn = draw(image, width: size.width, height: size.height), let png = SeriesArt.png(drawn) {
                try png.write(to: out)
                return out
            }
        }
        // Nothing drawn: a wrapper around one picture is that picture.
        let embedded = SeriesDesign.embeddedImages(clean)
        if embedded.count == 1, let data = embedded.first,
           let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let type = CGImageSourceGetType(source) as String?,
           let ext = UTType(type)?.preferredFilenameExtension, rasterExtensions.contains(ext) {
            let picture = out.deletingPathExtension().appendingPathExtension(ext)
            try data.write(to: picture)
            return picture
        }
        throw ImportError.drewNothing(name)
    }

    /// The image drawn into a clear bitmap; nil when not one pixel of it
    /// shows.
    private nonisolated static func draw(_ image: NSImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The graphics context is per thread, so this is safe off the main one.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var drewSomething = false
        rows: for row in 0..<height {
            let start = row * context.bytesPerRow
            for column in 0..<width where bytes[start + column * 4 + 3] != 0 {
                drewSomething = true
                break rows
            }
        }
        return drewSomething ? context.makeImage() : nil
    }

    // MARK: Looking

    private struct Look {
        var transparentAtTop: Bool
        var aspect: Double
        /// See-through across its upper part, or a strip far wider than a
        /// screen: a bar, not a background.
        var isLowerThird: Bool { transparentAtTop || aspect >= 3 }
    }

    /// A 256-pixel thumbnail is plenty to tell a see-through top from an
    /// opaque one, and reads a large image without decoding all of it.
    private nonisolated static func look(_ url: URL) -> Look? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0
        else { return nil }
        let aspect = Double(thumbnail.width) / Double(thumbnail.height)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(thumbnail.alphaInfo)
        guard hasAlpha, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return Look(transparentAtTop: false, aspect: aspect) }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * thumbnail.height)
        // Bitmap rows run top down in memory.
        let samples = [(0.5, 0.1), (0.2, 0.3), (0.8, 0.3)]
        let clear = samples.allSatisfy { fx, fy in
            let x = min(thumbnail.width - 1, Int(Double(thumbnail.width) * fx))
            let y = min(thumbnail.height - 1, Int(Double(thumbnail.height) * fy))
            return bytes[y * context.bytesPerRow + x * 4 + 3] < 13
        }
        return Look(transparentAtTop: clear, aspect: aspect)
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
