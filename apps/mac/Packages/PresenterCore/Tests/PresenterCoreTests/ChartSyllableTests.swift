import Foundation
import Testing
@testable import PresenterCore

/// Shepherd charts split words into syllables with a dash, sometimes with
/// the chord beside the dash; the slides show the word whole.
@Suite struct ChartSyllableTests {
    private func cleaned(_ line: String) -> String? {
        LyricCleanup.cleanLine(line, removePunctuation: true, chart: true)
    }

    @Test func aChordBesideTheDashKeepsTheWordWhole() {
        #expect(cleaned("You [5sus]see a moun  [42]- tain moved") == "You [5sus]see a moun[42]tain moved")
        #expect(cleaned("God You [5sus]see the emp  [1]- ty tomb") == "God You [5sus]see the emp[1]ty tomb")
        #expect(cleaned("That makes me [6m7]cry ho     [5]- ly") == "That makes me [6m7]cry ho[5]ly")
        #expect(cleaned("And the angels [42]cry Ho [6m7]-  [5]ly") == "And the angels [42]cry Ho[6m7][5]ly")
    }

    @Test func plainSplitsAndHyphenatedWordsAreAsBefore() {
        #expect(cleaned("and [42]all who will be - [1]lieve") == "and [42]all who will be[1]lieve")
        #expect(cleaned("Spirit-filled and ever- more") == "Spirit-filled and evermore")
    }
}
