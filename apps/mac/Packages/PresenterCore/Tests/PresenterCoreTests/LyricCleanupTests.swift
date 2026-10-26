import Foundation
import Testing
@testable import PresenterCore

@Test func dropsChordOnlyAndBarLines() {
    #expect(LyricCleanup.cleanLine("[G] / / / | [D] / / / | [Em] / /") == nil)
    #expect(LyricCleanup.cleanLine("[(Bb)] [/] [/] [/]") == nil)
    #expect(LyricCleanup.cleanLine("x2") == nil)
}

@Test func removesPunctuationAndRejoinsSplitWords() {
    #expect(LyricCleanup.cleanLine("We worship the God who ever - more will be,", chart: true) == "We worship the God who evermore will be")
    #expect(LyricCleanup.cleanLine("My God, he holds the vic - tory, yeah!", chart: true) == "My God he holds the victory yeah")
    #expect(LyricCleanup.cleanLine("We worship the God who ever- more will be") == "We worship the God who evermore will be")
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

@Test func punctuationGoesWordsStay() {
    #expect(LyricCleanup.cleanLine("Oh, how He loves us; so!") == "Oh how He loves us so")
    #expect(LyricCleanup.cleanLine("Is this the end? No… “It is finished.”") == "Is this the end No It is finished")
    #expect(LyricCleanup.cleanLine("I can't stop, I'm singin' 'til the end") == "I can't stop I'm singin' 'til the end")
    #expect(LyricCleanup.cleanLine("Twenty-two years, 'cause You're good") == "Twenty-two years 'cause You're good")
    #expect(LyricCleanup.cleanLine("Holy is the Lord (Hallelujah)") == "Holy is the Lord Hallelujah")
    #expect(LyricCleanup.cleanLine("Wond’ring where You are") == "Wond’ring where You are")
}

@Test func dashesUsedAsPunctuationGo() {
    #expect(LyricCleanup.cleanLine("Jesus - my Lord") == "Jesus my Lord")
    #expect(LyricCleanup.cleanLine("Jesus – my Lord — my King") == "Jesus my Lord my King")
    #expect(LyricCleanup.cleanLine("Lord—You are good") == "Lord You are good")
    #expect(LyricCleanup.cleanLine("And I will sing -") == "And I will sing")
    #expect(LyricCleanup.cleanLine("- and on") == "and on")
    #expect(LyricCleanup.cleanLine("Forever--amen") == "Forever amen")
}

@Test func chartSplitsJoinBeforeDashesAreRemoved() {
    #expect(LyricCleanup.cleanLine("And I'm a vag - a - [C]bond") == "And I'm a vaga[C]bond")
    #expect(LyricCleanup.cleanLine("You found me, For - [C/E]ever!") == "You found me For[C/E]ever")
    #expect(LyricCleanup.cleanLine("Your [G]love - it [D]never fails", chart: false) == "Your [G]love it [D]never fails")
    // In a chart a chord-free line follows the chart's rule.
    let chart = "[G]Ever - [D]more\nHal - le - lu - jah"
    #expect(LyricCleanup.clean(chart) == "[G]Ever[D]more\nHallelujah")
}

@Test func chordsKeepTheirLettersWhenCharactersGo() {
    #expect(LyricCleanup.cleanLine("You, [G]Lord, are [D]good!") == "You [G]Lord are [D]good")
    #expect(LyricCleanup.cleanLine("(\"[C]Holy\")") == "[C]Holy")
    let extracted = ChordMath.extractLine(LyricCleanup.cleanLine("Oh, the [Em]wonder, of [C]it all")!)
    #expect(extracted.text == "Oh the wonder of it all")
    #expect(extracted.chords.map(\.column) == [7, 17])
}

@Test func punctuationCanBeKept() {
    #expect(LyricCleanup.cleanLine("Oh, how He loves us!", removePunctuation: false) == "Oh, how He loves us!")
    #expect(LyricCleanup.cleanLine("vic - [G]tory, yeah!", removePunctuation: false) == "vic[G]tory, yeah!")
    #expect(LyricCleanup.cleanLine("[G] / / / | [D]", removePunctuation: false) == nil)
    #expect(LyricCleanup.clean("Verse 1\nGrace, grace!\n\nChorus (x2)", removePunctuation: false) == "Verse 1\nGrace, grace!\n\nChorus")
}

@Test func sectionNamesAndChordSymbolsAreUntouched() {
    #expect(LyricCleanup.cleanLine("Pre-Chorus 2") == "Pre-Chorus 2")
    #expect(LyricCleanup.cleanLine("[C#m7/G#]Here [Bbsus4]I am") == "[C#m7/G#]Here [Bbsus4]I am")
}
