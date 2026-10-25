import Foundation
import Testing
@testable import PresenterCore

/// Following a passage as it's read aloud. The chapters here are from the
/// King James Version (public domain); the follower doesn't care which
/// translation it is given.
private enum Chapter {
    static let romans8: [BibleVerse] = [
        (26, "Likewise the Spirit also helpeth our infirmities: for we know not what we should pray for as we ought: but the Spirit itself maketh intercession for us with groanings which cannot be uttered."),
        (27, "And he that searcheth the hearts knoweth what is the mind of the Spirit, because he maketh intercession for the saints according to the will of God."),
        (28, "And we know that all things work together for good to them that love God, to them who are the called according to his purpose."),
        (29, "For whom he did foreknow, he also did predestinate to be conformed to the image of his Son, that he might be the firstborn among many brethren."),
        (30, "Moreover whom he did predestinate, them he also called: and whom he called, them he also justified: and whom he justified, them he also glorified."),
        (31, "What shall we then say to these things? If God be for us, who can be against us?"),
        (32, "He that spared not his own Son, but delivered him up for us all, how shall he not with him also freely give us all things?"),
        (33, "Who shall lay any thing to the charge of God's elect? It is God that justifieth."),
        (34, "Who is he that condemneth? It is Christ that died, yea rather, that is risen again, who is even at the right hand of God, who also maketh intercession for us."),
        (35, "Who shall separate us from the love of Christ? shall tribulation, or distress, or persecution, or famine, or nakedness, or peril, or sword?"),
    ].map { BibleVerse(chapter: 8, verse: $0.0, text: $0.1) }

    static let john3: [BibleVerse] = [
        (14, "And as Moses lifted up the serpent in the wilderness, even so must the Son of man be lifted up:"),
        (15, "That whosoever believeth in him should not perish, but have eternal life."),
        (16, "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."),
        (17, "For God sent not his Son into the world to condemn the world; but that the world through him might be saved."),
        (18, "He that believeth on him is not condemned: but he that believeth not is condemned already, because he hath not believed in the name of the only begotten Son of God."),
    ].map { BibleVerse(chapter: 3, verse: $0.0, text: $0.1) }

    static let psalm136: [BibleVerse] = [
        (1, "O give thanks unto the LORD; for he is good: for his mercy endureth for ever."),
        (2, "O give thanks unto the God of gods: for his mercy endureth for ever."),
        (3, "O give thanks to the Lord of lords: for his mercy endureth for ever."),
        (4, "To him who alone doeth great wonders: for his mercy endureth for ever."),
        (5, "To him that by wisdom made the heavens: for his mercy endureth for ever."),
        (6, "To him that stretched out the earth above the waters: for his mercy endureth for ever."),
    ].map { BibleVerse(chapter: 136, verse: $0.0, text: $0.1) }

    static let matthew10: [BibleVerse] = [
        (1, "And when he had called unto him his twelve disciples, he gave them power against unclean spirits, to cast them out, and to heal all manner of sickness and all manner of disease."),
        (2, "Now the names of the twelve apostles are these; The first, Simon, who is called Peter, and Andrew his brother; James the son of Zebedee, and John his brother;"),
        (3, "Philip, and Bartholomew; Thomas, and Matthew the publican; James the son of Alphaeus, and Lebbaeus, whose surname was Thaddaeus;"),
    ].map { BibleVerse(chapter: 10, verse: $0.0, text: $0.1) }

    /// Written for these tests, to try contractions against a modern text.
    static let modern: [BibleVerse] = [
        (1, "Do not let your hearts be troubled; you cannot add a single hour to the span of your life by worrying."),
        (2, "I will not leave you as orphans in the valley; I am coming back to the river where the cedars grow."),
    ].map { BibleVerse(chapter: 1, verse: $0.0, text: $0.1) }

    static func text(_ verses: [BibleVerse], _ number: Int) -> String {
        verses.first { $0.verse == number }!.text
    }
}

/// The recognizer's way of writing speech: no punctuation, lower case.
private func spoken(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: "", options: .regularExpression)
}

/// Feeds text a phrase at a time (about eight words, as finished phrases
/// arrive) and returns every place it moved to.
@discardableResult
private func read(_ text: String, into follower: inout ScriptureFollower) -> [ScriptureFollower.Place] {
    let words = spoken(text).split(separator: " ").map(String.init)
    var places: [ScriptureFollower.Place] = []
    var start = 0
    while start < words.count {
        let phrase = words[start..<min(start + 8, words.count)].joined(separator: " ")
        if let place = follower.hear(phrase) { places.append(place) }
        start += 8
    }
    return places
}

@Suite struct ScriptureFollowerTests {

    @Test func findsTheVerseFromAnExactReading() throws {
        var follower = ScriptureFollower(verses: Chapter.romans8)
        let places = read(Chapter.text(Chapter.romans8, 28), into: &follower)
        #expect(follower.matchedLastPhrase)
        let first = try #require(places.first)
        #expect(first.verse == 28 && first.chapter == 8 && first.kind == .located)
        #expect(first.evidence >= ScriptureFollower.Threshold.locate)
        #expect(follower.place?.verse == 28)
    }

    @Test func followsVerseByVerseAsItIsRead() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 28)
        var verses: [Int] = []
        for verse in 28...32 {
            read(Chapter.text(Chapter.romans8, verse), into: &follower)
            verses.append(follower.place?.verse ?? 0)
        }
        #expect(verses == [28, 29, 30, 31, 32], "\(verses)")
    }

    @Test func toleratesMisheardWords() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 28)
        // "foreknow" heard as "for no", "predestinate" as "predestined",
        // "conformed" as "confirmed", "brethren" as "brother and".
        read("for whom he did for no he also did predestined to be confirmed to the image of his son that he might be the first born among many brother and", into: &follower)
        #expect(follower.place?.verse == 29)
        read("moreover whom he did predestinate them he also cold and whom he called them he also just a fight and whom he justified them he also glorified", into: &follower)
        #expect(follower.place?.verse == 30)
    }

    @Test func findsAPassageDespiteDroppedAndExtraWords() {
        var follower = ScriptureFollower(verses: Chapter.romans8)
        read("um likewise the spirit helps our infirmities for we know not what we should pray for uh as we ought but the spirit itself makes intercession", into: &follower)
        #expect(follower.place?.verse == 26)
    }

    @Test func movesOnWhenAVerseIsSkipped() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 28)
        read(Chapter.text(Chapter.romans8, 30), into: &follower)
        #expect(follower.place?.verse == 30, "one verse skipped is still reading on")
        read(Chapter.text(Chapter.romans8, 33) + " " + Chapter.text(Chapter.romans8, 34), into: &follower)
        #expect(follower.place?.verse == 34, "further ahead is a jump, which a full verse supports")
    }

    @Test func followsReadingOutOfOrder() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 30)
        let places = read(Chapter.text(Chapter.romans8, 27), into: &follower)
        #expect(follower.place?.verse == 27)
        #expect(places.last?.kind == .jumped)
        read(Chapter.text(Chapter.romans8, 35), into: &follower)
        #expect(follower.place?.verse == 35)
    }

    @Test func aFewWordsBackDoNotMoveIt() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 31)
        // Quoting a scrap of an earlier verse while preaching on this one.
        #expect(follower.hear("remember he is the firstborn") == nil)
        #expect(follower.place?.verse == 31)
    }

    @Test func sermonTalkDoesNotMatch() {
        var follower = ScriptureFollower(verses: Chapter.romans8)
        let talk = [
            "good morning church it is so good to see all of you here this morning",
            "I want you to think about the last time you felt really alone",
            "when I was a kid my dad used to take us fishing up at the lake every summer",
            "and he said to them",
            "God is good all the time and all the time God is good",
            "so what does that mean for us this week at work and at home",
        ]
        for line in talk {
            #expect(follower.hear(line) == nil, "\(line)")
            #expect(!follower.matchedLastPhrase)
        }
        #expect(follower.place == nil)
    }

    @Test func sermonTalkDoesNotMoveAPlaceAlreadyFound() {
        var follower = ScriptureFollower(verses: Chapter.romans8, at: 28)
        read(Chapter.text(Chapter.romans8, 28), into: &follower)
        for line in [
            "now I know some of you are going through things right now that do not feel good",
            "and the question is whether you believe that God is for you this morning",
            "he did it for his son and he will do it for you too",
            "because you were made in the image of a loving father",
        ] {
            follower.hear(line)
        }
        #expect(follower.place?.verse == 28)
    }

    @Test func shortCommonPhrasesDoNotTrigger() {
        for phrase in ["and he said to them", "and it came to pass", "Jesus said to them", "for God so loved"] {
            var follower = ScriptureFollower(verses: Chapter.john3)
            #expect(follower.hear(phrase) == nil, "\(phrase)")
            #expect(ScriptureFollower.searchQueries(recent: ScriptureFollower.words(phrase)).isEmpty)
        }
    }

    @Test func aSharedPhraseIsPlacedByWhatDiffers() {
        // 15 and 16 end almost alike; "everlasting" is 16.
        var follower = ScriptureFollower(verses: Chapter.john3)
        read(Chapter.text(Chapter.john3, 16), into: &follower)
        #expect(follower.place?.verse == 16)
    }

    @Test func aRefrainAloneIsNotEnoughToPlace() {
        // Every verse of Psalm 136 ends "for his mercy endureth for ever".
        var follower = ScriptureFollower(verses: Chapter.psalm136)
        #expect(follower.hear("for his mercy endureth for ever for his mercy endureth for ever") == nil)
        read(Chapter.text(Chapter.psalm136, 4), into: &follower)
        #expect(follower.place?.verse == 4)
        read(Chapter.text(Chapter.psalm136, 5), into: &follower)
        #expect(follower.place?.verse == 5)
    }

    @Test func numbersAndContractionsMatchTheText() {
        var follower = ScriptureFollower(verses: Chapter.matthew10)
        read("and when he had called unto him his 12 disciples he gave them power against unclean spirits to cast them out", into: &follower)
        #expect(follower.place?.verse == 1)

        var modern = ScriptureFollower(verses: Chapter.modern)
        read("don't let your hearts be troubled you can't add a single hour to the span of your life by worrying", into: &modern)
        #expect(modern.place?.verse == 1)
        read("I won't leave you as orphans in the valley I'm coming back to the river where the cedars grow", into: &modern)
        #expect(modern.place?.verse == 2)
    }

    @Test func wordsSpellOutContractionsAndNumbers() {
        #expect(ScriptureFollower.words("Don't, can't; won't — I'm, let's") == ["do", "not", "can", "not", "will", "not", "i", "am", "let", "us"])
        #expect(ScriptureFollower.words("his twelve disciples") == ScriptureFollower.words("his 12 disciples"))
        #expect(ScriptureFollower.words("You cannot") == ["you", "can", "not"])
        #expect(ScriptureFollower.words("God’s elect") == ["gods", "elect"])
    }

    @Test func emptyChaptersAndPhrasesAreHarmless() {
        var empty = ScriptureFollower(verses: [])
        #expect(empty.hear("for God so loved the world") == nil)
        var follower = ScriptureFollower(verses: Chapter.john3)
        #expect(follower.hear("") == nil)
        #expect(follower.hear("um uh") == nil)
    }

    // MARK: Search

    @Test func searchQueriesComeFromDistinctiveWords() {
        let heard = ScriptureFollower.words("and we know that all things work together for good to them that love god to them who are the called according to his purpose")
        let queries = ScriptureFollower.searchQueries(recent: heard)
        #expect(!queries.isEmpty)
        #expect(queries.first?.contains("purpose") == true)
        #expect(queries.allSatisfy { !$0.split(separator: " ").contains("the") }, "stopwords are left out")
        #expect(queries.count <= 3)
    }

    @Test func talkIsNotSearched() {
        for talk in [
            "okay so I want you guys to turn and look at your neighbor and say hello",
            "the thing is we are gonna have a great time at the picnic next week",
            "good morning",
            "and he said to them that it came to pass",
        ] {
            #expect(ScriptureFollower.searchQueries(recent: ScriptureFollower.words(talk)).isEmpty, "\(talk)")
        }
    }

    @Test func picksTheSearchResultThatFits() throws {
        let romans = try #require(BibleReference.book(named: "Romans"))
        let corinthians = try #require(BibleReference.book(named: "1 Corinthians"))
        let results: [(reference: BibleReference, text: String)] = [
            (BibleReference(book: corinthians, chapter: 2, startVerse: 9), "But as it is written, Eye hath not seen, nor ear heard, neither have entered into the heart of man, the things which God hath prepared for them that love him."),
            (BibleReference(book: romans, chapter: 8, startVerse: 28), Chapter.text(Chapter.romans8, 28)),
        ]
        let heard = ScriptureFollower.words("we know that all things work together for good to them that love god to them who are the called")
        let hit = try #require(ScriptureFollower.bestSearchHit(heard: heard, results: results))
        #expect(hit.reference.display == "Romans 8:28")

        let talk = ScriptureFollower.words("I love God and I know he is working on things in my life")
        #expect(ScriptureFollower.bestSearchHit(heard: talk, results: results) == nil)
    }

    @Test func twoPlacesThatFitAlikeAreNotPicked() throws {
        let matthew = try #require(BibleReference.book(named: "Matthew"))
        let luke = try #require(BibleReference.book(named: "Luke"))
        let saying = "No man can serve two masters: for either he will hate the one, and love the other"
        let results: [(reference: BibleReference, text: String)] = [
            (BibleReference(book: matthew, chapter: 6, startVerse: 24), saying + "; or else he will hold to the one, and despise the other."),
            (BibleReference(book: luke, chapter: 16, startVerse: 13), saying + "; or else he will hold to the one, and despise the other."),
        ]
        let heard = ScriptureFollower.words("no man can serve two masters for either he will hate the one and love the other")
        #expect(ScriptureFollower.bestSearchHit(heard: heard, results: results) == nil)
    }

    @Test func searchResultsDecode() throws {
        let json = #"{"page":1,"total_results":1,"results":[{"reference":"Romans 8:28","content":"And we know that for those who love God..."}],"total_pages":1}"#
        let results = try BibleService.esvSearchResults(from: Data(json.utf8))
        #expect(results == [ESVSearchResult(reference: "Romans 8:28", content: "And we know that for those who love God...")])
        #expect(try BibleService.esvSearchResults(from: Data(#"{"page":1,"results":[]}"#.utf8)).isEmpty)
        let url = BibleService.esvSearchURL(query: "work together good purpose", pageSize: 20)
        #expect(url.absoluteString.hasPrefix("https://api.esv.org/v3/passage/search/?q="))
        #expect(url.query?.contains("page-size=20") == true)
    }

    // MARK: Slides

    @Test func mapsAVerseToItsSlide() throws {
        let romans = try #require(BibleReference.book(named: "Romans"))
        let psalms = try #require(BibleReference.book(named: "Psalms"))
        let names = ["Romans 8:26–27", "Romans 8:28", "Romans 8:28", "Romans 8:29–31", "Romans 8:39–9:2"]
        func slide(_ chapter: Int, _ verse: Int) -> Int? {
            ScriptureFollower.slideIndex(book: romans, chapter: chapter, verse: verse, slideNames: names)
        }
        #expect(slide(8, 27) == 0)
        #expect(slide(8, 28) == 1, "a verse split over two slides starts at its first")
        #expect(slide(8, 30) == 3)
        #expect(slide(9, 1) == 4)
        #expect(slide(8, 35) == nil)
        #expect(ScriptureFollower.slideIndex(book: psalms, chapter: 23, verse: 1, slideNames: ["Psalms 23:1–3"]) == 0)
        #expect(ScriptureFollower.slideIndex(book: psalms, chapter: 8, verse: 28, slideNames: names) == nil, "another book's slides")
    }

    // MARK: Pacing

    @Test func searchesWaitBetweenRequests() {
        var pacer = ScriptureSearchPacer()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(pacer.wait(at: start) == 0)
        pacer.recordRequest(at: start)
        #expect(pacer.wait(at: start.addingTimeInterval(1)) == 3)
        #expect(pacer.wait(at: start.addingTimeInterval(5)) == 0)
    }

    @Test func searchesBackOffWhenTheAPISaysTooMany() {
        var pacer = ScriptureSearchPacer()
        let start = Date(timeIntervalSince1970: 1_000_000)
        pacer.recordRequest(at: start)
        pacer.rateLimited(at: start, retryAfter: nil)
        #expect(pacer.wait(at: start) == 60)
        pacer.rateLimited(at: start, retryAfter: nil)
        #expect(pacer.wait(at: start) == 120, "doubles when it happens again")
        pacer.rateLimited(at: start, retryAfter: 600)
        #expect(pacer.wait(at: start) == 600, "or waits what the API asks")
        pacer.succeeded()
        pacer.rateLimited(at: start, retryAfter: nil)
        #expect(pacer.wait(at: start) == 60)
    }

    @Test func searchesStopForTheDayAtTheCeiling() {
        var pacer = ScriptureSearchPacer()
        pacer.dailyLimit = 3
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<3 {
            pacer.recordRequest(at: now)
            now = now.addingTimeInterval(10)
        }
        #expect(pacer.wait(at: now) == nil)
        #expect(pacer.wait(at: now.addingTimeInterval(86_400)) == 0, "a new day starts again")
    }
}
