import Foundation

/// Builds a song from two sources: the clean lyrics (Planning Center's
/// lyrics field) for the words, and the chord chart for the chords. Chords
/// land on lyric lines whose words match a chart line, so a chart that's
/// laid out oddly can cost a chord but never a lyric.
public enum SongAssembly {

    public static func presentation(
        lyrics: String?, chordChart: String?, title: String, themeId: String, linesPerSlide: Int = 2
    ) -> Presentation? {
        let chartChordPro = chordChart.flatMap { chart -> String? in
            let trimmed = chart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pro = LyricTextImporter.detectFormat(trimmed) == .chordPro ? trimmed : ChordChartImport.chordPro(fromChart: trimmed)
            return LyricCleanup.clean(pro)
        }
        let words = lyrics.map { LyricCleanup.clean($0) }?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let source = (words?.isEmpty == false ? words : nil) ?? chartChordPro else { return nil }
        var presentation = LyricTextImporter.makePresentation(
            source, fallbackTitle: title, themeId: themeId, linesPerSlide: linesPerSlide)
        presentation.name = title

        if let chartChordPro, source != chartChordPro {
            let chart = LyricTextImporter.normalize(chartChordPro)
            if presentation.musicKey == nil { presentation.musicKey = chart.musicKey }
            presentation = attachingChords(from: chartChordPro, to: presentation)
            presentation.chordProSource = chart.chordProSource ?? chartChordPro
        }
        return presentation
    }

    /// Lays each chart line's chords onto the slide lines with the same words.
    public static func attachingChords(from chordPro: String, to presentation: Presentation) -> Presentation {
        var byLine: [String: [ChordPlacement]] = [:]
        for line in chordPro.components(separatedBy: "\n") {
            let extracted = ChordMath.extractLine(line)
            guard !extracted.chords.isEmpty else { continue }
            let key = LyricCleanup.matchKey(extracted.text)
            guard !key.isEmpty, byLine[key] == nil else { continue }
            byLine[key] = extracted.chords.map { ChordPlacement(line: 0, column: $0.column, symbol: $0.symbol) }
        }
        guard !byLine.isEmpty else { return presentation }
        var result = presentation
        for slideIndex in result.slides.indices {
            for objectIndex in result.slides[slideIndex].objects.indices
            where result.slides[slideIndex].objects[objectIndex].objectKind == .text {
                let lines = result.slides[slideIndex].objects[objectIndex].text.components(separatedBy: "\n")
                var placements: [ChordPlacement] = []
                for (lineIndex, line) in lines.enumerated() {
                    guard let chords = byLine[LyricCleanup.matchKey(line)] else { continue }
                    let length = line.count
                    placements += chords.map {
                        ChordPlacement(line: lineIndex, column: min($0.column, max(0, length)), symbol: $0.symbol)
                    }
                }
                if !placements.isEmpty {
                    result.slides[slideIndex].objects[objectIndex].chords = placements
                }
            }
        }
        return result
    }
}
