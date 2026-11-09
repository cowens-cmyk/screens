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

    @Test func decksChangedInTheBrowserDecode() throws {
        for name in try names("deck-") {
            let deck = try decode(Presentation.self, name)
            #expect(deck.slides.map(\.id) == (try meta(name)["slides"] as? [String] ?? []), "\(name)")
        }
    }
}
