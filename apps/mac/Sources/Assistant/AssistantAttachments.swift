import AppKit
import Foundation
import ImageIO
import PDFKit
import PresenterCore
import UniformTypeIdentifiers

/// A picture the user gave the Assistant: an image file, or one page of a
/// PDF rendered to an image. The model sees a reduced JPEG; the Media
/// library gets the full-size file if the picture becomes a slide.
struct AssistantAttachment: Identifiable, Sendable, Equatable {
    var id: String
    /// "Fall Festival.pdf, page 1".
    var label: String
    /// Full-size image to import (a copy in a temporary folder).
    var fileURL: URL
    /// JPEG for the model, at most 1568 pixels on the long side.
    var preview: Data

    var block: AssistantJSON {
        ["type": "image", "source": [
            "type": "base64", "media_type": "image/jpeg", "data": .string(preview.base64EncodedString()),
        ]]
    }
}

enum AssistantAttachments {
    static let allowedTypes: [UTType] = [.pdf, .jpeg, .png, .heic]
    static let limit = 20

    /// Copies or renders the files into a temporary folder and makes the
    /// model's previews, off the main thread. Ids continue from `startingAt`.
    static func prepare(_ urls: [URL], startingAt first: Int) async -> [AssistantAttachment] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("screens-assistant-\(UUID().uuidString)", isDirectory: true)
        return await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var made: [AssistantAttachment] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                let pages: [(label: String, file: URL)]
                if url.pathExtension.lowercased() == "pdf" {
                    pages = renderPDF(url, into: folder)
                } else {
                    let copy = folder.appendingPathComponent("\(made.count + 1)-\(name)")
                    pages = (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? [] : [(name, copy)]
                }
                for page in pages where made.count < limit {
                    guard let preview = jpegPreview(of: page.file) else { continue }
                    made.append(AssistantAttachment(
                        id: "att_\(first + made.count)", label: page.label, fileURL: page.file, preview: preview))
                }
            }
            return made
        }.value
    }

    /// One PNG per page, 1920 pixels wide, as Import Keynote or PDF does.
    private static func renderPDF(_ url: URL, into folder: URL) -> [(label: String, file: URL)] {
        guard let document = PDFDocument(url: url) else { return [] }
        let stem = url.deletingPathExtension().lastPathComponent
        return (0..<min(document.pageCount, limit)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1920 / max(bounds.width, 1)
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return nil }
            let file = folder.appendingPathComponent(
                document.pageCount == 1 ? "\(stem).png" : "\(stem) \(index + 1).png")
            guard (try? png.write(to: file)) != nil else { return nil }
            let label = document.pageCount == 1 ? url.lastPathComponent : "\(url.lastPathComponent), page \(index + 1)"
            return (label, file)
        }
    }

    private static func jpegPreview(of file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1568,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
