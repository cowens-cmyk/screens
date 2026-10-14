import Foundation
import Testing
@testable import PresenterCore

@Test func dropsChordOnlyAndBarLines() {
    #expect(LyricCleanup.cleanLine("[G] / / / | [D] / / / | [Em] / /") == nil)
    #expect(LyricCleanup.cleanLine("[(Bb)] [/] [/] [/]") == nil)
    #expect(LyricCleanup.cleanLine("x2") == nil)
}

@Test func removesPunctuationAndRejoinsSplitWords() {
    #expect(LyricCleanup.cleanLine("We worship the God who ever - more will be,") == "We worship the God who evermore will be")
    #expect(LyricCleanup.cleanLine("My God, he holds the vic - tory, yeah!") == "My God he holds the victory yeah")
    #expect(LyricCleanup.cleanLine("'Cause He hung upon that cross, then") == "'Cause He hung upon that cross then")
    #expect(LyricCleanup.cleanLine("My God's still rolling stones away.") == "My God's still rolling stones away")
}

@Test func chordsStayOnTheirWords() {
    let cleaned = LyricCleanup.cleanLine("[G]We worship the [D]God who was, we [Em]wor - ship")
    #expect(cleaned == "[G]We worship the [D]God who was we [Em]worship")
}

@Test func labelsAndDirectivesPassThrough() {
    #expect(LyricCleanup.cleanLine("Chorus 1") == "Chorus 1")
    #expect(LyricCleanup.cleanLine("{key: A}") == "{key: A}")
}

@Test func wholeSongCleanup() {
    let song = """
    Intro
    [A] / / / | [E] / / /

    Verse 1
    We worship the God who was, we worship the God who is
    We worship the God who ever - more will be

    Chorus
    This is the house of the Lord!
    """
    let cleaned = LyricCleanup.clean(song)
    #expect(!cleaned.contains("/"))
    #expect(cleaned.contains("We worship the God who was we worship the God who is"))
    #expect(cleaned.contains("This is the house of the Lord"))
}

@Test func lyricsComeFromLyricsChordsFromChart() {
    let lyrics = """
    Verse 1
    We worship the God who was, we worship the God who is
    We worship the God who ever-more will be

    Chorus
    This is the house of the Lord
    """
    let chart = """
    INTRO
    A / / / | E / / /

    VERSE 1
    A                    E
    We worship the God who was, we worship the God who is
    """
    let song = SongAssembly.presentation(lyrics: lyrics, chordChart: chart, title: "House Of The Lord", themeId: "")
    let texts = song?.slides.flatMap { $0.objects.map(\.text) } ?? []
    #expect(texts.contains { $0.contains("This is the house of the Lord") }, "the chorus from the lyrics is kept")
    #expect(!texts.joined().contains("/"))
    let verse = song?.slides.first { $0.objects.first?.text.hasPrefix("We worship") == true }
    #expect(verse?.objects.first?.chords?.map(\.symbol) == ["A", "E"])
}
