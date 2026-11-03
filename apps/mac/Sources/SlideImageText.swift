import AppKit
import Foundation
import ImageIO
import PresenterCore
import Vision

/// What the pictures on sermon slides say, so listening can follow a
/// sermon made of graphics. The words baked into a graphic are read on
/// this Mac (Vision); a photo with next to none gets a short description
/// from Claude when an Assistant key is set. Each picture is read once:
/// the answers are kept by the file's hash, on disk.
@MainActor
@Observable
final class SlideImageText {
    static let shared = SlideImageText()

    /// Bumps when a picture's words arrive, so a follower rebuilds.
    private(set) var version = 0

    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var loaded = false

    private init() {}

    /// The words a slide carries: its text, what its pictures say, and
    /// its name when that's more than a number.
    func text(for slide: Slide, model: AppModel) -> String {
        var parts = slide.objects.filter { $0.objectKind == .text }.map(\.text)
        for id in Self.mediaIDs(on: slide) {
            if let hash = model.media(id)?.fileHash, let words = cache[hash] { parts.append(words) }
        }
        if !slide.name.isEmpty, slide.name.contains(where: \.isLetter), !parts.joined().contains(slide.name) {
            parts.append(slide.name)
        }
        return parts.joined(separator: "\n")
    }

    /// Starts reading every picture on these slides not read yet.
    func prepare(_ slides: [Slide], model: AppModel) {
        loadIfNeeded()
        for slide in slides {
            for id in Self.mediaIDs(on: slide) {
                guard let item = model.media(id), item.mediaKind == .image,
                      cache[item.fileHash] == nil, !reading.contains(item.fileHash),
                      let entry = model.indexEntry(id), let url = model.fileURL(of: entry)
                else { continue }
                read(url, hash: item.fileHash)
            }
        }
    }

    static func mediaIDs(on slide: Slide) -> [String] {
        var ids: [String] = []
        if let id = slide.background?.mediaId, !id.isEmpty { ids.append(id) }
        for object in slide.objects {
            if let id = object.mediaId, !id.isEmpty { ids.append(id) }
            if let id = object.fill?.mediaId, !id.isEmpty { ids.append(id) }
        }
        return ids
    }

    private func read(_ url: URL, hash: String) {
        reading.insert(hash)
        Task {
            let words = await Task.detached(priority: .utility) { Self.recognize(url) }.value
            var answer = words
            // A photo with hardly a word on it: ask what it shows.
            if words.split(separator: " ").count < 3, !ClaudeClient.apiKey.isEmpty,
               let jpeg = await Task.detached(priority: .utility, operation: { Self.jpeg(url) }).value {
                if let description = try? await ClaudeClient.describeSlide(jpeg: jpeg) {
                    answer = [words, description].filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
            reading.remove(hash)
            cache[hash] = answer
            version += 1
            save()
        }
    }

    /// The text Vision reads off the picture, top to bottom.
    nonisolated static func recognize(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// The picture as a JPEG no wider than 1024, for Claude.
    nonisolated static func jpeg(_ url: URL) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Kept on disk

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Screens", isDirectory: true)
            .appendingPathComponent("slide-image-text.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        cache.merge(stored) { current, _ in current }
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension ClaudeClient {
    /// One or two sentences on what a sermon slide's picture shows, in the
    /// words a pastor would use talking about it.
    static func describeSlide(jpeg: Data) async throws -> String {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["description": ["type": "string"]],
            "required": ["description"],
            "additionalProperties": false,
        ]
        let json = try await send(
            system: "You describe sermon slides so live listening can tell when the pastor reaches each one. Say in one or two plain sentences what the picture shows, naming people, places, objects and any words on it. No opinions.",
            schema: schema, effort: "low",
            content: [
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["type": "text", "text": "Describe this slide."],
            ])
        struct Answer: Decodable { var description: String }
        return try JSONDecoder().decode(Answer.self, from: Data(json.utf8)).description
    }
}
