import Foundation
import XCTest
@testable import PresenterCore

/// Temporary: writes each song's tracked Shepherd chart (raw) and its slides.
final class ChartDumpRun: XCTestCase {
    @LibraryActor
    func testDump() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CHART_DUMP_DIR"], let keyPath = env["SHEPHERD_API_KEY_FILE"] else { throw XCTSkip("no") }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ShepherdClient(apiKey: key)
        let root = URL(fileURLWithPath: dir)
        let out = root.appendingPathComponent("tracked")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var songs: [[String: Any]] = []
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("lib"), includingPropertiesForKeys: nil)
        where file.pathExtension == "automerge" {
            let p = try TypedDocument<Presentation>(data: Data(contentsOf: file)).value
            guard p.presentationKind == .song, let id = p.shepherdSongId else { continue }
            let song = try await client.song(id: id)
            let arrangement = ShepherdSongImport.trackedArrangement(of: song, id: p.shepherdArrangementId)
            let text = ShepherdSongImport.source(song: song, arrangement: arrangement)?.text ?? ""
            try text.write(to: out.appendingPathComponent("\(p.name).txt"), atomically: true, encoding: .utf8)
            let names = Dictionary((p.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            songs.append([
                "name": p.name, "arrangement": arrangement?.name ?? "-", "key": p.musicKey ?? "-",
                "slides": p.slides.map { s in [
                    "section": s.sectionId.flatMap { names[$0] } ?? "",
                    "objects": s.objects.filter { $0.objectKind == .text }.map { o in [
                        "text": o.text,
                        "chords": (o.chords ?? []).map { ["line": $0.line, "column": $0.column, "symbol": $0.symbol] },
                    ] as [String: Any] },
                ] as [String: Any] },
            ])
        }
        try JSONSerialization.data(withJSONObject: songs, options: [.prettyPrinted]).write(to: root.appendingPathComponent("songs.json"))
    }
}
