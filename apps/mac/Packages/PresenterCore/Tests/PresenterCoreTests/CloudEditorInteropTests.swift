import Automerge
import Foundation
import Testing

@testable import PresenterCore

/// Documents changed by the CMS's browser editor (screensEditorModel in the
/// CMS Worker) still decode here, and a text edit made there moves style
/// runs, chords and animation ranges exactly as replaceText(with:) does.
/// The fixtures come from the CMS repo's editor test:
/// SCREENS_EDITOR_FIXTURES=<dir written by test/screens-editor-test.mjs>
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCREENS_EDITOR_FIXTURES"] != nil))
struct CloudEditorInteropTests {
    private let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENS_EDITOR_FIXTURES"] ?? "/")

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let document = try Document(Data(contentsOf: dir.appendingPathComponent(name + ".automerge")))
        return try AutomergeDecoder(doc: document).decode(T.self)
    }

    private func meta(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name + ".json"))) as? [String: Any] ?? [:]
    }

    private func names(_ prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".automerge") }
            .map { String($0.dropLast(".automerge".count)) }
            .sorted()
    }

    @Test func textEditsMoveWhatIsAnchoredAsTheMacDoes() throws {
        let befores = try names("text-").filter { $0.hasSuffix("-before") }
        #expect(befores.count >= 5)
        for before in befores {
            let info = try meta(before)
            let after = before.replacingOccurrences(of: "-before", with: "-after")
            var expected = try decode(Presentation.self, before).slides[0].objects[0]
            expected.replaceText(with: info["after"] as? String ?? "")
            let got = try decode(Presentation.self, after).slides[0].objects[0]
            #expect(got == expected, "\(before)")
        }
    }

    @Test func plansChangedInTheBrowserDecode() throws {
        let plans = try names("plan-")
        #expect(!plans.isEmpty)
        for name in plans {
            let service = try decode(Service.self, name)
            let info = try meta(name)
            let items = (info["items"] as? [[String]]) ?? []
            #expect(service.items.map { [$0.itemKind.rawValue, $0.name] } == items, "\(name)")
            #expect((service.preServiceRemoved ?? false) == (info["preServiceRemoved"] as? Bool ?? false))
        }
    }

    /// A song as the words and sections a person sees: each slide's section
    /// name, text and chords, then the default order by section name. Ids
    /// are new on each side, so they're left out.
    private func shape(_ song: Presentation) -> [String] {
        let names = Dictionary((song.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out = song.slides.map { slide in
            let text = slide.objects.first { $0.objectKind == .text }
            let chords = (text?.chords ?? []).map { "\($0.line):\($0.column):\($0.symbol)" }.joined(separator: ",")
            return "\(slide.sectionId.flatMap { names[$0] } ?? "-")|\(text?.text ?? "")|\(chords)|\(slide.themeSlideName ?? "")"
        }
        for arrangement in song.arrangements ?? [] {
            out.append("order \(arrangement.name): " + arrangement.sectionIds.map { names[$0] ?? "?" }.joined(separator: ","))
        }
        out.append("sections: " + (song.sections ?? []).map { "\($0.name)\($0.colorHex.map { " " + $0 } ?? "")" }.joined(separator: ","))
        return out
    }

    @Test func aSongMadeFromLyricsInTheBrowserIsTheSongReflowMakes() throws {
        let info = try meta("lyrics-new")
        let text = info["text"] as? String ?? ""
        let perSlide = info["perSlide"] as? Int ?? 2
        let made = try decode(Presentation.self, "lyrics-new")
        let built = Reflow.build(Reflow.parse(text, linesPerSlide: perSlide).openingOnBlank())
        var expected = made
        expected.slides = built.slides
        expected.sections = built.sections
        expected.arrangements = built.arrangement.map { [$0] }
        #expect(!text.isEmpty && made.presentationKind == .song)
        #expect(shape(made) == shape(expected))
    }

    @Test func lyricsChangedInTheBrowserMatchReflowApply() throws {
        let info = try meta("lyrics-before")
        let text = info["text"] as? String ?? ""
        let before = try decode(Presentation.self, "lyrics-before")
        let after = try decode(Presentation.self, "lyrics-after")
        var expected = before
        // The editor keeps a song opening on its blank slide (Reflow.apply
        // alone would drop it, having no words for it).
        var parsed = Reflow.parse(text, linesPerSlide: info["perSlide"] as? Int ?? 2)
        if before.slides.first?.objects.contains(where: { $0.objectKind == .text && !$0.text.isEmpty }) != true {
            parsed = parsed.openingOnBlank()
        }
        Reflow.apply(Reflow.build(parsed), to: &expected)
        expected.reflowSource = text
        #expect(shape(after) == shape(expected))
        #expect(after.reflowSource == text)
        // Sections still there keep their ids, so orders and plan items find them.
        let kept = Set((before.sections ?? []).map(\.id)).intersection((after.sections ?? []).map(\.id))
        #expect(kept == Set((expected.sections ?? []).map(\.id)).intersection((before.sections ?? []).map(\.id)))
        #expect(after.defaultArrangementId == expected.defaultArrangementId)
    }

    @Test func songsSplitThemedAndReorderedInTheBrowserDecode() throws {
        let split = try decode(Presentation.self, "song-split")
        #expect(split.slides.map { $0.objects.first?.text ?? "" } == (try meta("song-split")["slides"] as? [String] ?? []))
        #expect(split.slides[1].objects[0].chords == [ChordPlacement(line: 0, column: 5, symbol: "C")])
        let themed = try decode(Presentation.self, "song-theme")
        #expect(themed.themeId == "T2" && themed.slides.allSatisfy { $0.themeId == nil })
        let ordered = try decode(Presentation.self, "song-orders")
        let names = Dictionary((ordered.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let order = ordered.arrangements?.first { $0.name == "Ableton" }?.sectionIds.compactMap { names[$0] }
        #expect(order == (try meta("song-orders")["order"] as? [String]))
    }

    /// Pictures and videos added in the browser: media items as
    /// MediaImporter makes them, and slides as MediaSlides.make makes them,
    /// with "_LowerThird" pictures as the slides' livestream lower thirds.
    @Test func picturesAndVideosAddedInTheBrowserDecode() throws {
        let picture = try decode(MediaItem.self, "media-image")
        #expect(picture.mediaKind == .image && picture.fileStatus == .ready && picture.pixelWidth == 1920)
        #expect(picture.statusDetail == "Added in the browser")
        let video = try decode(MediaItem.self, "media-video")
        #expect(video.mediaKind == .video && video.durationSeconds == 31.5 && video.pixelWidth == nil)

        let deck = try decode(Presentation.self, "browser-deck")
        let info = try meta("browser-deck")
        #expect(deck.presentationKind == .deck && deck.category == PresentationTypes.sermon)
        #expect(deck.slides.count == info["slides"] as? Int)
        #expect(deck.slides[0].background?.layer == .stillGraphics)
        #expect(deck.slides[0].streamDesign?.lowerThirdImageID == info["lowerThird"] as? String)
        let bumper = try #require(deck.slides.first { $0.id == info["video"] as? String })
        #expect(bumper.background?.layer == .videos && bumper.background?.loops == false)
        #expect(bumper.autoAdvance?.afterPlayback == true && bumper.autoAdvance?.delaySeconds == 0)
        #expect(bumper.streamDesign?.mode == .audience)
        #expect(bumper.actions?.map(\.kind) == [.setStageMode] && bumper.actions?.first?.stageMode == "message")
        let typed = try #require(deck.slides.first { $0.id == info["typed"] as? String })
        #expect(typed.themeSlideName == "Scripture" && typed.themeId == "T1")
        #expect(typed.objects.map(\.name) == ["Reference", "Verse"] && typed.objects.allSatisfy { $0.objectKind == .text })
        #expect(typed.objects.last?.text == "Joseph interprets the dreams")
        let plain = try #require(deck.slides.first { $0.id == info["plain"] as? String })
        #expect(plain.unthemed == true && plain.objects.first?.width == 1600 && plain.objects.first?.objectKind == .text)

        let plan = try decode(Service.self, "browser-plan")
        #expect(plan.items.contains { $0.itemKind == .presentation && $0.refId == (try? meta("browser-plan"))?["refId"] as? String })
        #expect(plan.transitionRemoved == true)
    }

    /// The browser's stage and livestream tags (screensEditorModel.screenTags)
    /// are the ones Present shows, item by item and slide by slide.
    @Test func browserTagsMatchTheMacs() throws {
        func load<T: Decodable>(_ kind: String, _ type: T.Type) throws -> [String: T] {
            var out: [String: T] = [:]
            for name in try names("tags-\(kind)-") { out[String(name.dropFirst("tags-\(kind)-".count))] = try decode(T.self, name) }
            return out
        }
        let presentations = try load("presentation", Presentation.self)
        let media = try load("media", MediaItem.self)
        let themes = try load("theme", Theme.self)
        let plan = try decode(Service.self, "tags-service-TAGS-PLAN")
        let want = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("tags.json"))) as? [String: Any] ?? [:]
        let library = StageStreamTags.Library(
            presentation: { presentations[$0] }, media: { media[$0] }, theme: { themes[$0] }, settings: nil)
        #expect(want.count >= 8)
        for item in plan.items {
            let tags = StageStreamTags.tags(for: item, in: plan, library: library)
            #expect(tags.map { [$0.stage, $0.stream] } == want[item.id] as? [String], "\(item.name)")
            for slide in presentations[item.refId]?.slides ?? [] {
                let one = StageStreamTags.tags(for: slide, of: item, in: plan, library: library)
                #expect(one.map { [$0.stage, $0.stream] } == want[item.id + "#" + slide.id] as? [String], "\(item.name) \(slide.name)")
            }
        }
    }

    @Test func decksChangedInTheBrowserDecode() throws {
        for name in try names("deck-") {
            let deck = try decode(Presentation.self, name)
            #expect(deck.slides.map(\.id) == (try meta(name)["slides"] as? [String] ?? []), "\(name)")
        }
    }
}
