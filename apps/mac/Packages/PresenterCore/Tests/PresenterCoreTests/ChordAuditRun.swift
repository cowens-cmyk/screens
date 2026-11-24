import Foundation
import XCTest
@testable import PresenterCore

/// Not a test: compares every song in a snapshot of the library's
/// presentations with what Screens would build from its Shepherd chart
/// today, line by line. Runs only with CHORD_AUDIT_DIR (the snapshot) and
/// SHEPHERD_API_KEY set; writes report.json and report.txt there.
final class ChordAuditRun: XCTestCase {

    struct LineChords {
        var section: String
        var text: String
        var occurrence: Int
        var chords: [(word: Int, symbol: String)]
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The word a chord sits over: how many words start before its column.
    static func wordIndex(_ line: String, column: Int) -> Int {
        let chars = Array(line)
        var count = 0
        var inWord = false
        for (i, c) in chars.enumerated() {
            if i >= column { break }
            let wordChar = c.isLetter || c.isNumber
            if wordChar && !inWord { count += 1 }
            inWord = wordChar
        }
        // A chord at the start of a word belongs to that word.
        if column < chars.count, (chars[column].isLetter || chars[column].isNumber),
           column == 0 || !(chars[column - 1].isLetter || chars[column - 1].isNumber) {
            return count
        }
        return max(0, count - 1)
    }

    static func lines(_ p: Presentation) -> [LineChords] {
        let slides = Dictionary(p.slides.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ChordEdits.lines(of: p).map { ref in
            let object = slides[ref.slideID]?.objects.first { $0.id == ref.objectID }
            let lineText = object?.text.components(separatedBy: "\n")[safe: ref.line] ?? ref.text
            let chords = (object?.chords ?? []).filter { $0.line == ref.line }
                .sorted { $0.column < $1.column }
                .map { (word: wordIndex(lineText, column: $0.column), symbol: $0.symbol) }
            return LineChords(section: ref.section, text: ref.text, occurrence: ref.occurrence, chords: chords)
        }
    }

    /// A note or a Nashville number ("b7", "#4") as a pitch class.
    static func pitch(_ text: String, key: Int?) -> Int? {
        if let note = ChordMath.parseKey(text) { return note.pitchClass }
        guard let key else { return nil }
        var t = Substring(text)
        var accidental = 0
        while let c = t.first, c == "b" || c == "#" || c == "♭" || c == "♯" {
            accidental += (c == "#" || c == "♯") ? 1 : -1
            t = t.dropFirst()
        }
        guard let d = Int(t), (1...7).contains(d) else { return nil }
        return (key + [0, 2, 4, 5, 7, 9, 11][d - 1] + accidental + 24) % 12
    }

    /// Splits "6m7/5" or "#4°7" or "F#m7/E" into root, suffix, bass.
    static func split(_ symbol: String) -> (root: String, suffix: String, bass: String?)? {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        var root = ""
        var rest = Substring(head)
        while let c = rest.first, c == "b" || c == "#" || c == "♭" || c == "♯" { root.append(c); rest = rest.dropFirst() }
        if let c = rest.first, c.isNumber {
            root.append(c); rest = rest.dropFirst()
        } else if let c = rest.first, "ABCDEFG".contains(c) {
            root = String(c); rest = rest.dropFirst()
            if let a = rest.first, a == "#" || a == "b" || a == "♯" || a == "♭" { root.append(a); rest = rest.dropFirst() }
        } else {
            return nil
        }
        return (root, String(rest), parts.count > 1 ? parts[1] : nil)
    }

    /// Root, quality and bass by pitch, so C# and Db, and 1 and A in A, are
    /// the same chord.
    static func pitchKey(_ symbol: String, key: String?) -> String {
        let tonic = key.flatMap(ChordMath.parseKey)?.pitchClass
        guard let parts = split(symbol), let root = pitch(parts.root, key: tonic) else {
            return symbol.trimmingCharacters(in: .whitespaces)
        }
        let bass = parts.bass.flatMap { pitch($0, key: tonic) }.map { "/\($0)" } ?? (parts.bass.map { "/" + $0 } ?? "")
        let suffix = parts.suffix.replacingOccurrences(of: "maj", with: "M").replacingOccurrences(of: "min", with: "m")
            .replacingOccurrences(of: "-", with: "m")
        return "\(root)\(suffix)\(bass)"
    }

    struct SongReport: Codable {
        var name: String
        var presentationID: String
        var shepherdSongID: String?
        var shepherdTitle: String?
        var linked: Bool
        var status: String
        var screensKey: String?
        var shepherdKey: String?
        var handEdits: Int
        var linesCompared: Int
        var linesWithChordDiffs: Int
        var linesWithPositionDiffs: Int
        var linesNotInShepherd: Int
        var examples: [String]
        var chartHashMatches: Bool?
    }

    @LibraryActor
    func testAudit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CHORD_AUDIT_DIR"], let keyPath = env["SHEPHERD_API_KEY_FILE"] else {
            throw XCTSkip("audit not requested")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ShepherdClient(apiKey: key)
        let folder = URL(fileURLWithPath: dir)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "automerge" }
        var reports: [SongReport] = []
        var dryRun = ""
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let doc = try TypedDocument<Presentation>(data: Data(contentsOf: file))
            let p = doc.value
            guard p.presentationKind == .song else { continue }
            var report = SongReport(
                name: p.name, presentationID: p.id, shepherdSongID: p.shepherdSongId, shepherdTitle: nil,
                linked: p.shepherdSongId != nil, status: "", screensKey: p.musicKey, shepherdKey: nil,
                handEdits: p.chordEdits?.count ?? 0, linesCompared: 0, linesWithChordDiffs: 0, linesWithPositionDiffs: 0,
                linesNotInShepherd: 0, examples: [], chartHashMatches: nil)
            // The Shepherd song: the linked one, else a title match.
            var song: ShepherdClient.SongDetail?
            do {
                if let id = p.shepherdSongId, let linked = try? await client.song(id: id) {
                    song = linked
                } else {
                    let hits = try await client.searchSongs(p.name, limit: 10)
                    if let hit = hits.first(where: { Self.normalized($0.title) == Self.normalized(p.name) }) {
                        song = try await client.song(id: hit.id)
                    }
                }
            } catch {
                report.status = "shepherd error: \(error.localizedDescription)"
                reports.append(report)
                continue
            }
            guard let song else {
                report.status = "not found on Shepherd"
                reports.append(report)
                continue
            }
            report.shepherdSongID = song.id
            report.shepherdTitle = song.title
            let arrangement = ShepherdSongImport.trackedArrangement(of: song, id: p.shepherdArrangementId)
            if p.shepherdSongId != nil {
                report.chartHashMatches = p.shepherdChartHash == ShepherdSongImport.chartHash(song: song, arrangement: arrangement)
            }
            guard let fresh = ShepherdSongImport.presentation(song: song, arrangement: arrangement) else {
                report.status = "Shepherd has no chart or lyrics"
                reports.append(report)
                continue
            }
            report.shepherdKey = fresh.musicKey
            let plan = ShepherdChordMatch.matching(p, to: fresh)
            let after = ShepherdChordMatch.matching(plan.presentation, to: fresh)
            dryRun += "\(p.name): would change \(plan.changedLines) lines, drop \(plan.droppedHandEdits) hand edits, leave \(plan.unmatchedLines) lines the chart lacks; matched \(plan.matchedLines); after: \(after.changedLines) still differ\n"
            for e in plan.examples { dryRun += "    \(e)\n" }
            for u in plan.unmatchedWords { dryRun += "    UNMATCHED \(u)\n" }

            let theirs = Self.lines(fresh)
            var bySectionText: [String: LineChords] = [:]
            var byText: [String: LineChords] = [:]
            for line in theirs {
                let t = Self.normalized(line.text)
                guard !t.isEmpty else { continue }
                bySectionText["\(Self.normalized(line.section))|\(t)|\(line.occurrence)"] = line
                if byText["\(t)|\(line.occurrence)"] == nil { byText["\(t)|\(line.occurrence)"] = line }
            }
            var seen = Set<String>()
            for line in Self.lines(p) {
                let t = Self.normalized(line.text)
                guard !t.isEmpty else { continue }
                // A line repeated across slides of a section is compared once.
                let k = "\(Self.normalized(line.section))|\(t)|\(line.occurrence)"
                guard seen.insert(k).inserted else { continue }
                guard let match = bySectionText[k] ?? byText["\(t)|\(line.occurrence)"] ?? byText["\(t)|0"] else {
                    report.linesNotInShepherd += 1
                    continue
                }
                report.linesCompared += 1
                let mine = line.chords.map { Self.pitchKey($0.symbol, key: p.musicKey) }
                let ref = match.chords.map { Self.pitchKey($0.symbol, key: fresh.musicKey) }
                let mineAt = line.chords.map(\.word)
                let refAt = match.chords.map(\.word)
                if mine == ref, mineAt != refAt {
                    report.linesWithPositionDiffs += 1
                }
                if mine != ref {
                    report.linesWithChordDiffs += 1
                    if report.examples.count < 6 {
                        let a = line.chords.map { $0.symbol }.joined(separator: " ")
                        let b = match.chords.map { $0.symbol }.joined(separator: " ")
                        report.examples.append("[\(line.section)] \"\(line.text)\": Screens \(a.isEmpty ? "(none)" : a) | Shepherd \(b.isEmpty ? "(none)" : b)")
                    }
                }
            }
            if report.linesWithChordDiffs == 0 && report.linesCompared > 0 {
                report.status = report.linesWithPositionDiffs > 0 ? "same chords, some over other words" : "chords match"
            } else if report.linesCompared == 0 {
                report.status = "no lines in common"
            } else {
                report.status = "chords differ"
            }
            reports.append(report)
        }
        let json = try JSONEncoder().encode(reports)
        try json.write(to: folder.appendingPathComponent("report.json"))
        var text = ""
        for r in reports.sorted(by: { ($0.status, $0.name) < ($1.status, $1.name) }) {
            text += "\(r.name) — \(r.status); lines \(r.linesCompared), differ \(r.linesWithChordDiffs), moved \(r.linesWithPositionDiffs), not in chart \(r.linesNotInShepherd); key \(r.screensKey ?? "-")/\(r.shepherdKey ?? "-"); hand edits \(r.handEdits); linked \(r.linked); chart hash \(r.chartHashMatches.map { "\($0)" } ?? "-")\n"
            for e in r.examples { text += "    \(e)\n" }
        }
        try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try dryRun.write(to: folder.appendingPathComponent("dryrun.txt"), atomically: true, encoding: .utf8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
