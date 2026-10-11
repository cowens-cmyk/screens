import Foundation
import Testing
@testable import PresenterCore

@Test func parsesCommonReferenceForms() {
    let gen = BibleReference.parse("Turn to Genesis 32")!
    #expect(gen.book.code == "GEN" && gen.chapter == 32 && gen.startVerse == nil)
    let cor = BibleReference.parse("1 Cor 13:4–7")!
    #expect(cor.book.code == "1CO" && cor.startVerse == 4 && cor.endVerse == 7 && cor.endChapter == nil)
    #expect(cor.apiBiblePassageID == "1CO.13.4-1CO.13.7")
    let john = BibleReference.parse("John 3:16-4:2")!
    #expect(john.endChapter == 4 && john.endVerse == 2)
    #expect(BibleReference.parse("ps 23 v 1")?.book.name == "Psalms")
    #expect(BibleReference.parse("First John 1:9")?.book.code == "1JN")
    #expect(BibleReference.parse("II Timothy 3:16")?.book.code == "2TI")
    #expect(BibleReference.parse("hello world") == nil)
}

@Test func splitsMarkedVersesAcrossChapters() {
    let verses = ScriptureText.verses(fromMarked: "[16] For God so loved\n the world. [17] For God did not [1] Now there was", chapter: 3, startVerse: 16)
    #expect(verses.map(\.verse) == [16, 17, 1])
    #expect(verses.map(\.chapter) == [3, 3, 4])
}

@Test func removesLineBreaksByDefault() {
    let text = "The Lord is my shepherd;\n   I shall not want.\n\n"
    #expect(ScriptureText.clean(text, keepsLineBreaks: false) == "The Lord is my shepherd; I shall not want.")
    #expect(ScriptureText.clean(text, keepsLineBreaks: true) == "The Lord is my shepherd;\nI shall not want.")
}

@Test func slidesNeverStartMidVerse() {
    let verses = (1...6).map { BibleVerse(chapter: 1, verse: $0, text: String(repeating: "word ", count: 10)) }
    let format = ScriptureFormat(showsVerseNumbers: false)
    // Room for 25 words: two whole verses fit, a third would not.
    let pages = ScripturePaginator.paginate(verses, format: format) { $0.split(separator: " ").count <= 25 }
    #expect(pages.map { $0.verses.map(\.verse) } == [[1, 2], [3, 4], [5, 6]])
    #expect(pages.allSatisfy { !$0.continuesVerse })
    #expect(pages[1].text.hasPrefix("word"))
}

@Test func oversizedVerseContinuesThenNextVerseStartsFresh() {
    let verses = [
        BibleVerse(chapter: 1, verse: 1, text: String(repeating: "long ", count: 30)),
        BibleVerse(chapter: 1, verse: 2, text: "short"),
    ]
    let pages = ScripturePaginator.paginate(verses, format: ScriptureFormat(showsVerseNumbers: false)) {
        $0.split(separator: " ").count <= 20
    }
    #expect(pages.count == 3)
    #expect(pages[1].continuesVerse)
    #expect(pages[2].verses.map(\.verse) == [2] && pages[2].text == "short")
}

@Test func pageReferenceShowsItsOwnVerses() {
    let book = BibleReference.parse("John 3")!.book
    let page = ScripturePage(text: "", verses: [
        BibleVerse(chapter: 3, verse: 16, text: ""), BibleVerse(chapter: 3, verse: 17, text: ""),
    ], continuesVerse: false)
    #expect(page.reference(book: book) == "John 3:16–17")
}
