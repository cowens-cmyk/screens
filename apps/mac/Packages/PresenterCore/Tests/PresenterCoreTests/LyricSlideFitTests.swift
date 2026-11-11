import Foundation
import Testing
@testable import PresenterCore

/// A stand-in for the theme's Lyrics box: 24 characters to a line, each
/// written line taking as many lines as its length needs.
private let narrowBox: LyricSlideFit.LineCount = { _, _, text in
    text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 24).rounded(.up))) }
}

private let ancientGatesChart = """
Verse 1
[G]Lift up your heads O you [C]ancient gates
[Em]Be lifted up you [D]everlasting doors

Chorus
[C]Who is this King
[G]The Lord so strong
"""

private func ancientGates(chart: String = ancientGatesChart) -> ShepherdClient.SongDetail {
    ShepherdClient.SongDetail(
        id: "ag", title: "Ancient Gates", defaultKey: "G",
        arrangements: [ShepherdClient.SongArrangement(id: "a1", name: "Default", lengthSeconds: 300, sequence: [])],
        chordChart: chart, defaultArrangementId: "a1",
        chart: ShepherdClient.ChartInfo(format: "ChordPro", hasChart: true, writtenKey: "G"))
}

private func words(_ slide: Slide) -> String {
    slide.objects.first { $0.objectKind == .text }?.text ?? ""
}

private func sectionName(_ slide: Slide, in presentation: Presentation) -> String? {
    presentation.sections?.first { $0.id == slide.sectionId }?.name
}

private func song(_ slides: [Slide]) -> Presentation {
    var presentation = Presentation(
        id: "p", name: "Song", presentationKind: .song, themeId: "t", slides: slides,
        sections: [PresentationSection(id: "v1", name: "Verse 1")])
    presentation.category = PresentationTypes.worship
    return presentation
}

private func lyricSlide(_ text: String, chords: [ChordPlacement]? = nil, id: String = "s1") -> Slide {
    var box = SlideObject(id: "box-\(id)", objectKind: .text, name: "Lyrics", text: text)
    box.chords = chords
    var slide = Slide(id: id, name: "", objects: [box])
    slide.sectionId = "v1"
    slide.themeSlideName = "Lyrics"
    return slide
}

@Suite struct LyricSlideFitTests {

    @Test func importSplitsAWrappingSlideAndKeepsItsSection() throws {
        let options = ShepherdSongImport.Options(lineCount: narrowBox)
        let built = try #require(ShepherdSongImport.presentation(
            song: ancientGates(), arrangement: ancientGates().arrangements.first, options: options))
        let verse = built.slides.filter { sectionName($0, in: built) == "Verse 1" }
        #expect(verse.map(words) == ["Lift up your heads O you ancient gates", "Be lifted up you everlasting doors"])
        #expect(verse.allSatisfy { $0.themeSlideName == "Lyrics" })
        #expect(Set(verse.map(\.id)).count == 2)
        // Chords stay on their words.
        #expect(verse[0].objects[0].chords == [
            ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 0, column: 25, symbol: "C")])
        #expect(verse[1].objects[0].chords == [
            ChordPlacement(line: 0, column: 0, symbol: "Em"), ChordPlacement(line: 0, column: 17, symbol: "D")])
        // The chorus fits as it is.
        let chorus = built.slides.filter { sectionName($0, in: built) == "Chorus" }
        #expect(chorus.map(words) == ["Who is this King\nThe Lord so strong"])
        // As imported, so plan sync still treats it as Shepherd's.
        #expect(built.shepherdImportHash == ShepherdSongImport.fingerprint(built))
        let hash = ShepherdSongImport.chartHash(song: ancientGates(), arrangement: ancientGates().arrangements.first)
        #expect(ShepherdSongImport.decision(for: built, chartHash: hash) == .upToDate)
    }

    @Test func importWithoutACounterCutsByLinesAlone() throws {
        let built = try #require(ShepherdSongImport.presentation(song: ancientGates(), arrangement: nil))
        let verse = built.slides.filter { sectionName($0, in: built) == "Verse 1" }
        #expect(verse.count == 1)
    }

    @Test func refreshAfterAFitKeepsWorking() throws {
        let options = ShepherdSongImport.Options(lineCount: narrowBox)
        let plain = try #require(ShepherdSongImport.presentation(song: ancientGates(), arrangement: nil))
        // An older import, split later by the library pass.
        let fitted = LyricSlideFit.fit(plain, lineCount: narrowBox)
        #expect(fitted.changed)
        let newer = ancientGates(chart: ancientGatesChart + "\n\nTag\n[G]Lift up")
        let hash = ShepherdSongImport.chartHash(song: newer, arrangement: nil)
        #expect(ShepherdSongImport.decision(for: fitted.presentation, chartHash: hash) == .update)
        let fresh = try #require(ShepherdSongImport.presentation(song: newer, arrangement: nil, options: options))
        let updated = ShepherdSongImport.replacing(fitted.presentation, with: fresh)
        #expect(ShepherdSongImport.decision(for: updated, chartHash: hash) == .upToDate)
        #expect(updated.slides.map(words).contains("Lift up"))
    }

    @Test func aFittingSlideIsLeftAlone() {
        let slide = lyricSlide("Who is this King\nThe Lord strong")
        #expect(LyricSlideFit.split(slide, lineCount: narrowBox) == nil)
        let result = LyricSlideFit.fit(song([slide]), lineCount: narrowBox)
        #expect(!result.changed)
        #expect(result.presentation.slides == [slide])
    }

    @Test func aLongLineAloneIsCutAtAWordNearTheMiddle() throws {
        // 60 characters: three lines in the narrow box.
        let line = "Lift up your heads O you ancient gates be lifted up you doors"
        let chords = [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 25, symbol: "C"),
            ChordPlacement(line: 0, column: 32, symbol: "Em"), // over the space where it's cut
            ChordPlacement(line: 0, column: 56, symbol: "D"),
        ]
        let pieces = try #require(LyricSlideFit.split(lyricSlide(line, chords: chords), lineCount: narrowBox))
        #expect(pieces.count == 2)
        #expect(pieces.map(words) == ["Lift up your heads O you ancient", "gates be lifted up you doors"])
        #expect(pieces[0].objects[0].chords == [
            ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 0, column: 25, symbol: "C")])
        #expect(pieces[1].objects[0].chords == [
            ChordPlacement(line: 0, column: 0, symbol: "Em"), ChordPlacement(line: 0, column: 23, symbol: "D")])
        #expect(pieces.allSatisfy { narrowBox($0, $0.objects[0], words($0)) ?? 9 <= 2 })
    }

    @Test func halvesOfACutLineShareASlideWhenTheyFit() throws {
        // 41 characters is three lines 20 to a line; cut in the middle,
        // each half is one line, so the halves go back on one slide.
        let counter: LyricSlideFit.LineCount = { _, _, text in
            text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 20).rounded(.up))) }
        }
        let slide = lyricSlide("Lift up your heads O you ancient gates be\nEverlasting doors")
        let pieces = try #require(LyricSlideFit.split(slide, lineCount: counter))
        #expect(pieces.map(words) == ["Lift up your heads O\nyou ancient gates be", "Everlasting doors"],
                "a part of a line never shares a slide with the next line")
    }

    @Test func splitSlidesKeepWhatsOnTheSlide() throws {
        var slide = lyricSlide("Lift up your heads O you ancient gates\nBe lifted up", id: "first")
        slide.background = CueMedia(mediaId: "bg")
        slide.notes = "Build"
        slide.actions = [SlideAction(id: "a", kind: .clearAll)]
        slide.overrideDesigns = [OverrideDesign(themeId: "t2", themeSlideName: "Lower Third")]
        let pieces = try #require(LyricSlideFit.split(slide, lineCount: narrowBox))
        #expect(pieces.count == 2)
        #expect(Set(pieces.map(\.id) + ["first"]).count == 3, "new ids, so Undo can't half-undo a split")
        #expect(pieces[1].objects[0].id != pieces[0].objects[0].id)
        #expect(pieces.allSatisfy {
            $0.sectionId == "v1" && $0.themeSlideName == "Lyrics" && $0.background?.mediaId == "bg"
                && $0.notes == "Build" && $0.overrideDesigns == slide.overrideDesigns
        })
        #expect(pieces[0].actions == slide.actions)
        #expect(pieces[1].actions == nil, "a cue fires once, where the words begin")
    }

    @Test func slidesItCantSplitSafelyAreLeftAlone() {
        let long = "Lift up your heads O you ancient gates\nBe lifted up you everlasting doors"
        // Words over two boxes.
        var twoBoxes = lyricSlide(long)
        twoBoxes.objects.append(SlideObject(id: "b2", objectKind: .text, name: "Other", text: "More"))
        #expect(LyricSlideFit.split(twoBoxes, lineCount: narrowBox) == nil)
        // Styled runs pinned to lines.
        var styled = lyricSlide(long)
        styled.objects[0].styleRuns = [TextStyleRun(line: 1, column: 0, length: 2)]
        #expect(LyricSlideFit.split(styled, lineCount: narrowBox) == nil)
        // A blank slide, and one the counter can't measure.
        #expect(LyricSlideFit.split(Slide(id: "blank", name: "", objects: []), lineCount: narrowBox) == nil)
        #expect(LyricSlideFit.split(lyricSlide(long), lineCount: { _, _, _ in nil }) == nil)
        // A deck that isn't a song.
        var deck = song([lyricSlide(long)])
        deck.presentationKind = .deck
        deck.category = PresentationTypes.sermon
        #expect(!LyricSlideFit.fit(deck, lineCount: narrowBox).changed)
    }

    @Test func anEditedSongKeepsItsEditedMark() {
        var edited = song([lyricSlide("Lift up your heads O you ancient gates\nBe lifted up")])
        edited.shepherdImportHash = "something else"
        let result = LyricSlideFit.fit(edited, lineCount: narrowBox)
        #expect(result.changed && result.splitSlides == 1 && result.resultingSlides == 2)
        #expect(result.presentation.shepherdImportHash == "something else")
    }
}
