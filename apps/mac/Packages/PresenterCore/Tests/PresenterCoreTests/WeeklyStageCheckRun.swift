import Foundation
import XCTest
@testable import PresenterCore

/// Not a test: the weekly stage check (perf/tools/weekly-stage-check.sh).
/// For the songs in Shepherd's plans over the next days, checks against a
/// copy of the library what Match Chords to Shepherd would still change
/// (chords, chord-only parts, split words, extra spaces), lines the chart
/// lacks, songs not linked to Shepherd, and the key the stage shows against
/// the plan's key. Runs only with WEEKLY_CHECK_DIR (holding lib/*.automerge)
/// and SHEPHERD_API_KEY_FILE; writes report.txt there.
final class WeeklyStageCheckRun: XCTestCase {

    @LibraryActor
    func testWeeklyCheck() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["WEEKLY_CHECK_DIR"], let keyPath = env["SHEPHERD_API_KEY_FILE"] else {
            throw XCTSkip("not requested")
        }
        let days = Int(env["WEEKLY_CHECK_DAYS"] ?? "") ?? 8
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ShepherdClient(apiKey: key)
        let root = URL(fileURLWithPath: dir)

        // The library's songs, by Shepherd song id and by title.
        var songs: [Presentation] = []
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("lib"), includingPropertiesForKeys: nil)
        where file.pathExtension == "automerge" {
            let p = try TypedDocument<Presentation>(data: Data(contentsOf: file)).value
            if p.presentationKind == .song { songs.append(p) }
        }
        func librarySong(_ planSong: ShepherdClient.PlanSong?, title: String) -> Presentation? {
            if let id = planSong?.id, let linked = songs.first(where: { $0.shepherdSongId == id }) { return linked }
            let wanted = ShepherdChordMatch.normalized(planSong?.title ?? title)
            return songs.first { ShepherdChordMatch.normalized($0.name) == wanted }
        }

        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let until = Calendar.current.date(byAdding: .day, value: days, to: today)!
        let plans = try await client.plans(from: format.string(from: today), to: format.string(from: until))
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }

        var report = ""
        var problems = 0
        var checked = Set<String>()
        let day = DateFormatter()
        day.dateFormat = "EEE MMM d"
        for summary in plans {
            let plan = try await client.plan(id: summary.id)
            let items = plan.items.filter { $0.song != nil || $0.kind == "song" }
            guard !items.isEmpty else { continue }
            report += "\n\(summary.startsAt.map(day.string(from:)) ?? "?") — \(plan.title ?? plan.serviceType.name)\n"
            for item in items {
                let title = item.song?.title ?? item.title
                guard let song = librarySong(item.song, title: title) else {
                    report += "  ✗ \(title): not in the Screens library\n"
                    problems += 1
                    continue
                }
                var notes: [String] = []
                // The key the stage shows against the plan's.
                if let playing = item.song?.key, !playing.isEmpty, let musicKey = song.musicKey {
                    let shown = song.displayKey ?? musicKey
                    let wanted = ChordMath.displayKey(playing: playing, musicKey: musicKey) ?? playing
                    if ChordMath.parseKey(shown)?.pitchClass != ChordMath.parseKey(wanted)?.pitchClass {
                        notes.append("stage shows key \(shown), plan says \(playing) (Screens sets it when the plan syncs; check the plan synced)")
                    }
                }
                if checked.insert(song.id).inserted {
                    if let id = song.shepherdSongId, let detail = try? await client.song(id: id) {
                        let arrangement = ShepherdSongImport.trackedArrangement(of: detail, id: song.shepherdArrangementId)
                        if let chart = ShepherdSongImport.presentation(song: detail, arrangement: arrangement) {
                            let match = ShepherdChordMatch.matching(song, to: chart)
                            var would: [String] = []
                            if match.changedLines > 0 { would.append("\(match.changedLines) chord lines") }
                            if match.chordOnlySlides > 0 { would.append("\(match.chordOnlySlides) chord-only slides") }
                            if !match.joinedWords.isEmpty { would.append("split words \(Set(match.joinedWords).sorted())") }
                            if match.spacedLines > 0 { would.append("extra spaces on \(match.spacedLines) lines") }
                            if !would.isEmpty {
                                notes.append("Match Chords to Shepherd would fix: " + would.joined(separator: ", "))
                                for example in match.examples.prefix(4) { notes.append("    \(example)") }
                            }
                            if !match.unmatchedWords.isEmpty {
                                notes.append("lines the chart doesn't have (left as they are): \(match.unmatchedWords.count)")
                            }
                        } else {
                            notes.append("Shepherd has no chart or lyrics for it")
                        }
                    } else if song.shepherdSongId == nil {
                        notes.append("not linked to a Shepherd song")
                    } else {
                        notes.append("couldn't read it from Shepherd")
                    }
                }
                let real = notes.filter { !$0.hasPrefix("lines the chart") && !$0.hasPrefix("    ") }
                problems += real.count
                report += "  \(real.isEmpty ? "✓" : "✗") \(song.name)\(notes.isEmpty ? "" : ":")\n"
                for note in notes { report += "      \(note)\n" }
            }
        }
        if plans.isEmpty { report += "\nNo Shepherd plans in the next \(days) days.\n" }
        report = "Stage check \(format.string(from: today)): \(problems == 0 ? "all clear" : "\(problems) to look at")\n" + report
        try report.write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
