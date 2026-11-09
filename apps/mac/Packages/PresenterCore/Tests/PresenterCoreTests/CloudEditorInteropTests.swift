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

    @Test func decksChangedInTheBrowserDecode() throws {
        for name in try names("deck-") {
            let deck = try decode(Presentation.self, name)
            #expect(deck.slides.map(\.id) == (try meta(name)["slides"] as? [String] ?? []), "\(name)")
        }
    }
}
