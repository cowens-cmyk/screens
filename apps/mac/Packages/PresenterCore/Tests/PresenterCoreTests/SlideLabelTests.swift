import Foundation
import Testing
@testable import PresenterCore

struct SlideLabelTests {
    private func text(_ name: String, _ text: String) -> SlideObject {
        SlideObject(id: UUID().uuidString, objectKind: .text, name: name, text: text)
    }

    private func deck(
        _ name: String = "Deck", kind: PresentationKind = .deck, category: String? = nil,
        sections: [PresentationSection]? = nil, slides: [Slide]
    ) -> Presentation {
        var presentation = Presentation(
            id: UUID().uuidString, name: name, presentationKind: kind, themeId: "", slides: slides,
            sections: sections)
        presentation.category = category
        return presentation
    }

    private func scripture(_ id: String, name: String = "", verses: String, reference: String) -> Slide {
        Slide(id: id, name: name, objects: [text("Verse", verses), text("Reference", reference)], themeSlideName: "Bible")
    }

    // MARK: Scripture

    @Test func aScriptureSlideIsLabelledByItsVerse() {
        let slide = scripture("a", name: "Genesis 32:3", verses: "³ Jacob sent messengers", reference: "Genesis 32:3–8 ESV")
        let label = SlideLabels.label(for: slide, at: 0, in: deck("Genesis 32:3–8 (ESV)", category: "Bible", slides: [slide]))
        #expect(label == SlideLabel(title: "Genesis 32:3", detail: "ESV", isReference: true))
    }

    @Test func aScriptureSlideWithSeveralVersesShowsTheRange() {
        let slide = scripture("a", name: "Gen 32:3-5", verses: "³ … ⁴ … ⁵ …", reference: "Genesis 32:3–8 NIV")
        let label = SlideLabels.label(for: slide, at: 0, in: deck(category: "Bible", slides: [slide]))
        #expect(label.title == "Genesis 32:3–5", "the book's full name and an en dash, however it was typed")
        #expect(label.detail == "NIV")
    }

    @Test func aRangeAcrossChaptersKeepsBothChapters() {
        let slide = scripture("a", name: "Genesis 31:55–32:2", verses: "⁵⁵ … ¹ … ² …", reference: "Genesis 31:55–32:12 ESV")
        let label = SlideLabels.label(for: slide, at: 0, in: deck(category: "Bible", slides: [slide]))
        #expect(label.title == "Genesis 31:55–32:2")
    }

    @Test func anUnnamedScriptureSlideIsReadFromItsVerseNumbers() {
        let first = scripture("a", verses: "³\u{2009}Jacob sent ⁴\u{2009}instructing them", reference: "Genesis 32:3–8 ESV")
        let second = scripture("b", verses: "⁵\u{2009}I have oxen ⁶\u{2009}The messengers returned", reference: "Genesis 32:3–8 ESV")
        let presentation = deck("Genesis 32:3–8 (ESV)", category: "Bible", slides: [first, second])
        #expect(SlideLabels.label(for: second, at: 1, in: presentation)
            == SlideLabel(title: "Genesis 32:5–6", detail: "ESV", isReference: true))
        #expect(SlideLabels.label(for: first, at: 0, in: presentation).title == "Genesis 32:3–4")
    }

    @Test func verseNumbersStartingOverMeanTheNextChapter() {
        let first = scripture("a", verses: "⁵⁴ Early in the morning ⁵⁵ Laban arose", reference: "Genesis 31:54–32:3 ESV")
        let second = scripture("b", verses: "¹ Jacob went on ² When he saw them", reference: "Genesis 31:54–32:3 ESV")
        let third = scripture("c", verses: "³ And Jacob sent", reference: "Genesis 31:54–32:3 ESV")
        let presentation = deck(category: "Bible", slides: [first, second, third])
        #expect(SlideLabels.label(for: first, at: 0, in: presentation).title == "Genesis 31:54–55")
        #expect(SlideLabels.label(for: second, at: 1, in: presentation).title == "Genesis 32:1–2")
        #expect(SlideLabels.label(for: third, at: 2, in: presentation).title == "Genesis 32:3")
    }

    @Test func aPageThatOpensMidVerseCarriesThatVerse() {
        let first = scripture("a", verses: "¹⁶ For God so loved the world, that he", reference: "John 3:16–17 ESV")
        let second = scripture("b", verses: "should not perish ¹⁷ For God did not send", reference: "John 3:16–17 ESV")
        let presentation = deck(category: "Bible", slides: [first, second])
        #expect(SlideLabels.label(for: second, at: 1, in: presentation).title == "John 3:16–17")
    }

    @Test func scriptureWithoutVerseNumbersFallsBackToThePassage() {
        let slide = scripture("a", verses: "For God so loved the world", reference: "John 3:16 ESV")
        let label = SlideLabels.label(for: slide, at: 0, in: deck("John 3:16 (ESV)", category: "Bible", slides: [slide]))
        #expect(label == SlideLabel(title: "John 3:16", detail: "ESV", isReference: true))
    }

    @Test func readsTheTranslation() {
        #expect(SlideLabels.translation(in: "Genesis 32:3–8 ESV") == "ESV")
        #expect(SlideLabels.translation(in: "Psalm 23 (NKJV)") == "NKJV")
        #expect(SlideLabels.translation(in: "the Lord is my shepherd\nPsalm 23:1 CSB") == "CSB")
        #expect(SlideLabels.translation(in: "Genesis 32:3") == nil)
        #expect(SlideLabels.translation(in: nil) == nil)
    }

    // MARK: Songs

    @Test func aSongSlideIsLabelledByItsGroup() {
        let sections = [
            PresentationSection(id: "v1", name: "Verse 1"), PresentationSection(id: "ch", name: "Chorus"),
        ]
        let verse = Slide(id: "a", name: "", objects: [text("Lyrics", "Amazing grace\nhow sweet the sound")], sectionId: "v1")
        let chorus = Slide(id: "b", name: "", objects: [text("Lyrics", "  My chains are gone  ")], sectionId: "ch")
        let song = deck(kind: .song, sections: sections, slides: [verse, chorus])
        #expect(SlideLabels.label(for: verse, at: 0, in: song) == SlideLabel(title: "Verse 1", detail: "Amazing grace"))
        #expect(SlideLabels.label(for: chorus, at: 1, in: song) == SlideLabel(title: "Chorus", detail: "My chains are gone"))
    }

    // MARK: Message notes

    @Test func messageSlidesSayWhichPointTheyAre() {
        let title = Slide(id: "t", name: "Wrestling With God", objects: [text("Title", "Wrestling With God")], themeSlideName: "Title")
        let one = Slide(id: "p1", name: "God meets us", objects: [text("Point", "God meets us")], themeSlideName: "Sermon Points")
        let verse = scripture("s", name: "Genesis 32:24", verses: "²⁴ And Jacob was left alone", reference: "Genesis 32:24 ESV")
        let two = Slide(
            id: "p2", name: "", objects: [text("Point", "He renames us"), text("Verse", "…"), text("Reference", "Genesis 32:28 ESV")],
            themeSlideName: "Point + Scripture")
        let unnamed = Slide(id: "p3", name: "", objects: [], themeSlideName: "Sermon Points")
        let message = deck("Message", category: "Sermon", slides: [title, one, verse, two, unnamed])

        #expect(SlideLabels.label(for: title, at: 0, in: message) == SlideLabel(title: "Wrestling With God", detail: "Title"))
        #expect(SlideLabels.label(for: one, at: 1, in: message) == SlideLabel(title: "God meets us", detail: "Point 1"))
        #expect(SlideLabels.label(for: verse, at: 2, in: message)
            == SlideLabel(title: "Genesis 32:24", detail: "ESV", isReference: true))
        #expect(SlideLabels.label(for: two, at: 3, in: message)
            == SlideLabel(title: "He renames us", detail: "Point 2 · Genesis 32:28 ESV"))
        #expect(SlideLabels.label(for: unnamed, at: 4, in: message) == SlideLabel(title: "Point 3"))
    }

    // MARK: Media

    @Test func aMediaSlideIsLabelledByItsMedia() {
        let named = Slide(id: "a", name: "Welcome Loop.mp4", objects: [], background: CueMedia(mediaId: "m", layer: .videos))
        let unnamed = Slide(id: "b", name: "", objects: [], background: CueMedia(mediaId: "m", layer: .stillGraphics))
        let presentation = deck(slides: [named, unnamed])
        #expect(SlideLabels.label(for: named, at: 0, in: presentation, mediaName: "Welcome Loop.mp4").title == "Welcome Loop.mp4")
        #expect(SlideLabels.label(for: unnamed, at: 1, in: presentation, mediaName: "Announcements.png").title == "Announcements.png")
    }

    @Test func textOverABackgroundNamedForItsFileShowsTheText() {
        let slide = Slide(
            id: "a", name: "Mountains.mov", objects: [text("Text", "Welcome home")],
            background: CueMedia(mediaId: "m", layer: .loopingVideos))
        let label = SlideLabels.label(for: slide, at: 0, in: deck(slides: [slide]), mediaName: "Mountains")
        #expect(label.title == "Welcome home")
    }

    @Test func theCountdownSaysHowLongItRuns() {
        #expect(SlideLabels.mediaItem(name: "Countdown", isCountdown: true, durationSeconds: 300)
            == SlideLabel(title: "Countdown 5:00"))
        #expect(SlideLabels.mediaItem(name: "Fall Countdown.mp4", isCountdown: true, durationSeconds: 299.6)
            == SlideLabel(title: "Countdown 5:00", detail: "Fall Countdown.mp4"))
        #expect(SlideLabels.mediaItem(name: "Countdown", isCountdown: true, durationSeconds: nil) == SlideLabel(title: "Countdown"))
        #expect(SlideLabels.mediaItem(name: "Baptism Story", isCountdown: false, durationSeconds: 192)
            == SlideLabel(title: "Baptism Story", detail: "3:12"))
    }

    // MARK: Fallbacks

    @Test func aNamedSlideShowsItsName() {
        let slide = Slide(id: "a", name: "Giving", objects: [text("Text", "Give online at hopejc.org")])
        #expect(SlideLabels.label(for: slide, at: 0, in: deck(slides: [slide])) == SlideLabel(title: "Giving"))
    }

    @Test func anUnnamedSlideShowsItsFirstLineOfText() {
        let slide = Slide(id: "a", name: "", objects: [text("Text", "\n   Next   Steps  \nLunch after")])
        #expect(SlideLabels.label(for: slide, at: 0, in: deck(slides: [slide])) == SlideLabel(title: "Next Steps"))
    }

    @Test func anEmptySlideIsNumbered() {
        let slide = Slide(id: "a", name: "  ", objects: [text("Text", "")])
        #expect(SlideLabels.label(for: slide, at: 6, in: deck(slides: [slide])) == SlideLabel(title: "Slide 7"))
    }

    @Test func aGroupedSlideInADeckUsesItsNameFirst() {
        let sections = [PresentationSection(id: "w", name: "Welcome")]
        let named = Slide(id: "a", name: "Coffee", objects: [text("Text", "Coffee in the lobby")], sectionId: "w")
        let unnamed = Slide(id: "b", name: "", objects: [text("Text", "Kids check-in")], sectionId: "w")
        let presentation = deck(sections: sections, slides: [named, unnamed])
        #expect(SlideLabels.label(for: named, at: 0, in: presentation).title == "Coffee")
        #expect(SlideLabels.label(for: unnamed, at: 1, in: presentation) == SlideLabel(title: "Welcome", detail: "Kids check-in"))
    }
}
