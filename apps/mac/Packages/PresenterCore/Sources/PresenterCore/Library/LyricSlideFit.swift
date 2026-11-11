import Foundation

/// Song slides show at most two lines. A slide's words can take more than
/// two lines on screen even when they were written as two: a long lyric
/// line wraps in the theme's Lyrics box. Such a slide becomes several, each
/// with one or two lines, all in the same section, so the section label
/// (two "Verse 1" slides) and the song's orders stay as they were.
///
/// PresenterCore can't draw text, so the caller says how many lines a text
/// takes (SlideScene's LyricSlideFitter measures it against the theme).
public enum LyricSlideFit {

    public static let maxLines = 2

    /// How many lines `text` takes when it is the words of `box` on
    /// `slide`, drawn as the slide draws them. Nil when that can't be told,
    /// and the slide is then left alone.
    public typealias LineCount = @Sendable (_ slide: Slide, _ box: SlideObject, _ text: String) -> Int?

    public struct Result: Sendable {
        public var presentation: Presentation
        /// Slides that were split, counted before splitting.
        public var splitSlides: Int
        /// Slides the split ones became, in all.
        public var resultingSlides: Int

        public var addedSlides: Int { resultingSlides - splitSlides }
        public var changed: Bool { splitSlides > 0 }
    }

    /// The presentations this applies to: songs, and anything filed as Worship.
    public static func isWorship(_ presentation: Presentation) -> Bool {
        presentation.presentationKind == .song
            || PresentationTypes.category(of: presentation) == PresentationTypes.worship
    }

    /// `presentation` with every slide that runs past `maxLines` split.
    /// A song still as Shepherd imported it stays that way: its import
    /// fingerprint moves with the split, so plan sync keeps updating it.
    public static func fit(_ presentation: Presentation, maxLines: Int = maxLines, lineCount: LineCount) -> Result {
        guard isWorship(presentation) else {
            return Result(presentation: presentation, splitSlides: 0, resultingSlides: 0)
        }
        var slides: [Slide] = []
        var split = 0, resulting = 0
        for slide in presentation.slides {
            if let pieces = self.split(slide, maxLines: maxLines, lineCount: lineCount) {
                slides += pieces
                split += 1
                resulting += pieces.count
            } else {
                slides.append(slide)
            }
        }
        guard split > 0 else { return Result(presentation: presentation, splitSlides: 0, resultingSlides: 0) }
        var result = presentation
        let wasAsImported = presentation.shepherdImportHash != nil
            && presentation.shepherdImportHash == ShepherdSongImport.fingerprint(presentation)
        result.slides = slides
        if wasAsImported { result.shepherdImportHash = ShepherdSongImport.fingerprint(result) }
        return Result(presentation: result, splitSlides: split, resultingSlides: resulting)
    }

    // MARK: One slide

    /// A piece of one of the slide's lines: the whole line, or part of a
    /// line too long for two lines on its own.
    struct Piece: Equatable {
        var line: Int
        /// Where the piece starts in its line, in characters.
        var start: Int
        var text: String
        var whole: Bool
    }

    /// The slides `slide` becomes, or nil when it fits already or can't be
    /// split safely. Every one has a new id, the first included: Undo
    /// matches slides by id, and with the old id kept it would take the
    /// added slides away and leave the first one's words cut short.
    public static func split(_ slide: Slide, maxLines: Int = maxLines, lineCount: LineCount) -> [Slide]? {
        let maxLines = max(1, maxLines)
        // Words in one box only: words split over several boxes don't say
        // which lines go together.
        let worded = slide.objects.indices.filter {
            slide.objects[$0].objectKind == .text
                && !slide.objects[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard worded.count == 1 else { return nil }
        let boxIndex = worded[0]
        let box = slide.objects[boxIndex]
        // Things pinned to a line and column other than chords (styled
        // runs, per-line styles, text animations) aren't moved, so a slide
        // with them is left for a person.
        guard !box.text.contains("\r"), box.textLink == nil, (box.styleRuns ?? []).isEmpty,
              (box.textStyle?.lineStyles ?? []).isEmpty,
              !(box.animationSteps ?? []).contains(where: { !($0.ranges ?? []).isEmpty })
        else { return nil }

        guard let total = lineCount(slide, box, box.text), total > maxLines else { return nil }

        let lines = box.text.components(separatedBy: "\n")
        let chords = box.chords ?? []
        // A blank line with chords on it would lose them.
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).isEmpty {
            if chords.contains(where: { $0.line == index }) { return nil }
        }

        func count(_ text: String) -> Int? { lineCount(slide, box, text) }

        var pieces: [Piece] = []
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let whole = Piece(line: index, start: 0, text: line, whole: true)
            guard let lineTotal = count(line) else { return nil }
            if lineTotal <= maxLines {
                pieces.append(whole)
            } else {
                guard let halves = halve(whole, maxLines: maxLines, count: count) else { return nil }
                pieces += halves
            }
        }

        // Each chord goes with the piece its column falls in, at the same
        // place in that piece's words. One over the spaces where a line was
        // cut belongs to the word after them.
        var chordsByPiece: [[(column: Int, symbol: String)]] = Array(repeating: [], count: pieces.count)
        for chord in chords {
            let candidates = pieces.indices.filter { pieces[$0].line == chord.line }
            guard var owner = candidates.last(where: { pieces[$0].start <= chord.column }) ?? candidates.first
            else { continue }
            if chord.column >= pieces[owner].start + pieces[owner].text.count,
               let next = candidates.first(where: { $0 > owner }) {
                owner = next
            }
            let piece = pieces[owner]
            chordsByPiece[owner].append(
                (column: min(max(0, chord.column - piece.start), piece.text.count), symbol: chord.symbol))
        }

        // Pieces go together while they fit. A part of a line only joins
        // the rest of its own line, so no slide starts mid-line and ends
        // in the next one.
        var groups: [[Int]] = []
        for index in pieces.indices {
            let piece = pieces[index]
            if let last = groups.last, let first = last.first.map({ pieces[$0] }),
               first.line == piece.line || (piece.whole && last.allSatisfy { pieces[$0].whole }),
               let joined = count((last + [index]).map { pieces[$0].text }.joined(separator: "\n")),
               joined <= maxLines {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        guard groups.count > 1 else { return nil }

        return groups.enumerated().map { number, group in
            var made = slide
            var words = box
            words.text = group.map { pieces[$0].text }.joined(separator: "\n")
            if box.chords != nil {
                words.chords = group.enumerated().flatMap { row, index in
                    chordsByPiece[index].map { ChordPlacement(line: row, column: $0.column, symbol: $0.symbol) }
                }
            }
            made.objects[boxIndex] = words
            if number == 0 {
                made.id = UUID().uuidString
            } else {
                made = renewed(made)
            }
            return made
        }
    }

    /// `line` cut at the space nearest its middle, and each half again
    /// while it is still too long. Nil when a half can't be measured; a
    /// line with no space to cut at stays whole.
    static func halve(_ piece: Piece, maxLines: Int, count: (String) -> Int?) -> [Piece]? {
        guard let total = count(piece.text) else { return nil }
        let characters = Array(piece.text)
        guard total > maxLines, let cut = middleSpace(in: characters) else { return [piece] }
        var leftEnd = cut
        while leftEnd > 0, characters[leftEnd - 1] == " " { leftEnd -= 1 }
        var rightStart = cut
        while rightStart < characters.count, characters[rightStart] == " " { rightStart += 1 }
        guard leftEnd > 0, rightStart < characters.count else { return [piece] }
        let left = Piece(line: piece.line, start: piece.start, text: String(characters[..<leftEnd]), whole: false)
        let right = Piece(
            line: piece.line, start: piece.start + rightStart, text: String(characters[rightStart...]), whole: false)
        guard let leftPieces = halve(left, maxLines: maxLines, count: count),
              let rightPieces = halve(right, maxLines: maxLines, count: count) else { return nil }
        return leftPieces + rightPieces
    }

    /// The index of the space closest to the middle of the words, ignoring
    /// spaces at either end.
    static func middleSpace(in characters: [Character]) -> Int? {
        let middle = characters.count / 2
        let spaces = characters.indices.filter { index in
            characters[index] == " "
                && characters[..<index].contains { $0 != " " }
                && characters[(index + 1)...].contains { $0 != " " }
        }
        return spaces.min { abs($0 - middle) < abs($1 - middle) }
    }

    /// A copy of `slide` for a later piece: new ids for it and its objects
    /// (with what points at them following), and no history, which belongs
    /// to the first. Actions stay on the first piece too, so a cue fires
    /// once, where the words begin, as it did before.
    static func renewed(_ slide: Slide) -> Slide {
        var copy = slide
        copy.id = UUID().uuidString
        var ids: [String: String] = [:]
        for index in copy.objects.indices {
            let fresh = UUID().uuidString
            ids[copy.objects[index].id] = fresh
            copy.objects[index].id = fresh
        }
        for index in copy.objects.indices {
            if let mask = copy.objects[index].maskObjectId { copy.objects[index].maskObjectId = ids[mask] ?? mask }
        }
        copy.animationOrder = copy.animationOrder?.map { ids[$0] ?? $0 }
        copy.history = nil
        copy.actions = nil
        return copy
    }
}
