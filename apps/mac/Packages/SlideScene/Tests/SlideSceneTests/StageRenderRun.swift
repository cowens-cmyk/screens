import AppKit
import Foundation
import Metal
import XCTest
@testable import PresenterCore
@testable import RenderEngine
@testable import SlideScene

/// Not a test: draws what the stage display shows for every slide of every
/// song in a snapshot of the library, with the stage's Worship layout, the
/// way it is drawn for the stage output. Runs only with STAGE_RENDER_DIR set
/// (holding lib/*.automerge and worship.automerge); writes out/<song>/NN.png
/// and out/<song>.png, a contact sheet.
@MainActor
final class StageRenderRun: XCTestCase {

    static func png(_ frame: RenderedFrame, to url: URL, width: Int? = nil) throws {
        guard let image = frame.cgImage else { throw XCTSkip("no image") }
        let w = width ?? frame.width
        let h = w * frame.height / frame.width
        let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// The song's slides in the order its default arrangement plays them,
    /// each part once.
    static func slides(_ p: Presentation) -> [Slide] {
        guard let arrangement = p.arrangements?.first(where: { $0.id == p.defaultArrangementId }) ?? p.arrangements?.first
        else { return p.slides }
        var seen = Set<String>()
        var out: [Slide] = []
        for section in arrangement.sectionIds where seen.insert(section).inserted {
            out += p.slides.filter { $0.sectionId == section }
        }
        return out.isEmpty ? p.slides : out
    }

    @LibraryActor
    static func load<E: DocumentEntity>(_ type: E.Type, _ url: URL) throws -> E {
        try TypedDocument<E>(data: Data(contentsOf: url)).value
    }

    func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["STAGE_RENDER_DIR"] else { throw XCTSkip("not requested") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = URL(fileURLWithPath: dir)
        let layout = try await Self.load(ConfidenceLayout.self, root.appendingPathComponent("worship.automerge"))
        let only = ProcessInfo.processInfo.environment["STAGE_RENDER_ONLY"]
        let compositor = try Compositor()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("lib"), includingPropertiesForKeys: nil)
        var index = ""
        // With STAGE_MATCH_KEY_FILE (a Shepherd API key), each song is first
        // put through Match Chords to Shepherd, to see the stage after it.
        let client = try ProcessInfo.processInfo.environment["STAGE_MATCH_KEY_FILE"].map {
            ShepherdClient(apiKey: try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for file in files where file.pathExtension == "automerge" {
            var p = try await Self.load(Presentation.self, file)
            guard p.presentationKind == .song else { continue }
            if let only, !only.split(separator: ",").contains(where: { p.name.localizedCaseInsensitiveContains($0) }) { continue }
            if let client, let id = p.shepherdSongId {
                let song = try await client.song(id: id)
                let arrangement = ShepherdSongImport.trackedArrangement(of: song, id: p.shepherdArrangementId)
                if let chart = ShepherdSongImport.presentation(song: song, arrangement: arrangement) {
                    let match = ShepherdChordMatch.matching(p, to: chart)
                    index += "\(p.name): matched — \(match.changedLines) lines, \(match.chordOnlySlides) chord-only, \(match.spacedLines) spaced, joined \(match.joinedWords)\n"
                    p = match.presentation
                }
            }
            let names = Dictionary((p.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let slides = Self.slides(p)
            let folder = root.appendingPathComponent("out/\(p.name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            index += "\(p.name): key \(p.musicKey ?? "-") shown in \(p.displayKey ?? p.musicKey ?? "-"), \(slides.count) slides\n"
            var thumbs: [CGImage] = []
            for (i, slide) in slides.enumerated() {
                var info = ConfidenceInfo()
                info.current = ConfidenceSceneBuilder.slideText(for: slide, in: p)
                if i + 1 < slides.count {
                    info.next = ConfidenceSceneBuilder.slideText(for: slides[i + 1], in: p)
                    info.nextGroupName = slides[i + 1].sectionId.flatMap { names[$0] }
                }
                info.currentGroupName = slide.sectionId.flatMap { names[$0] }
                info.currentItemName = p.name
                info.currentPresentationName = p.name
                info.slidePosition = .init(index: i, total: slides.count)
                let scene = ConfidenceSceneBuilder.scene(layout: layout, info: info, at: Date(timeIntervalSince1970: 1_795_000_000))
                let frame = try compositor.renderFrame(scene: scene, width: 1920, height: 1080)
                try Self.png(frame, to: folder.appendingPathComponent(String(format: "%02d.png", i + 1)))
                if let image = frame.cgImage { thumbs.append(image) }
            }
            // A contact sheet, three across.
            let tw = 640, th = 360, across = 3
            let rows = (thumbs.count + across - 1) / across
            if rows > 0 {
                let sheet = CGContext(
                    data: nil, width: tw * across, height: th * rows, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                sheet.setFillColor(gray: 0.3, alpha: 1)
                sheet.fill(CGRect(x: 0, y: 0, width: tw * across, height: th * rows))
                for (n, image) in thumbs.enumerated() {
                    let x = (n % across) * tw, y = (rows - 1 - n / across) * th
                    sheet.draw(image, in: CGRect(x: x + 2, y: y + 2, width: tw - 4, height: th - 4))
                }
                try NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!
                    .write(to: root.appendingPathComponent("out/\(p.name).png"))
            }
        }
        try index.write(to: root.appendingPathComponent("out/index.txt"), atomically: true, encoding: .utf8)
    }
}
