import Foundation

/// Keeps the pastor's place in a chapter as he reads it aloud, from the
/// recognizer's finished phrases. The chapter's words are laid end to end and
/// the latest heard words are aligned against them (a local alignment, so
/// misheard, dropped and extra words cost a little rather than breaking the
/// match). The verse where the alignment ends is where he is.
///
/// It is built for precision: a wrong verse on screen mid-sermon is worse
/// than none. Common words ("and he said to them") count for nothing, words
/// sermons use all the time ("God", "love", "people") count for half, and a
/// place is only taken when several distinctive words line up in order and
/// no other part of the chapter fits nearly as well.
public struct ScriptureFollower: Sendable {

    /// Where the reader is.
    public struct Place: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// First found in the chapter.
            case located
            /// Read on into this verse.
            case forward
            /// Moved somewhere else in the chapter (back, or well ahead).
            case jumped
        }
        public var chapter: Int
        public var verse: Int
        /// Distinctive words heard in order that match the text (common
        /// words count half): how sure the place is.
        public var evidence: Double
        public var kind: Kind
    }

    /// The thresholds, together, so the tests and the app read the same ones.
    public enum Threshold {
        /// Finding a passage, or moving anywhere but just ahead.
        public static let locate = 5.0
        /// Putting a passage found from reading on screen without being asked.
        public static let show = 6.0
        /// Reading on into the next verse or two.
        public static let follow = 3.0
        /// Words in the newest phrase that must match before anything moves (one
        /// distinctive word, or two common ones),
        /// so an old match can't carry commentary along with it.
        public static let fresh = 1.0
        /// Words in the verse being moved into.
        public static let landing = 1.5
        /// How much better than any other part of the chapter a found place
        /// must fit (alignment score).
        public static let margin = 3.0
        /// A search result picked from the ESV search's list.
        public static let searchHit = 3.0
        public static let searchMargin = 2.0
    }

    public let verses: [BibleVerse]
    public private(set) var place: Place?
    /// The last phrase fit the text where he is (moving or not): he's
    /// still reading.
    public private(set) var matchedLastPhrase = false

    private let tokens: [Token]
    private var heard: [String] = []
    private var currentIndex: Int?

    /// `verse` is where reading is expected to start (a spoken reference),
    /// or nil to wait until the reading itself says where it is.
    public init(verses: [BibleVerse], at verse: Int? = nil) {
        self.verses = verses
        tokens = Self.tokens(for: verses)
        if let verse, let index = verses.firstIndex(where: { $0.verse == verse }) {
            currentIndex = index
            place = Place(chapter: verses[index].chapter, verse: verse, evidence: 0, kind: .located)
        }
    }

    /// The most heard words kept: a few phrases.
    static let memory = 30

    /// Feeds a finished phrase. Returns the new place when it changed.
    @discardableResult
    public mutating func hear(_ text: String) -> Place? {
        hear(words: Self.words(text))
    }

    @discardableResult
    public mutating func hear(words new: [String]) -> Place? {
        matchedLastPhrase = false
        let new = new.filter { !Self.fillers.contains($0) }
        guard !new.isEmpty, !tokens.isEmpty else { return nil }
        heard = Array((heard + new).suffix(Self.memory))
        let freshStart = heard.count - min(new.count, heard.count)
        let ends = Self.align(heard, tokens, freshFrom: freshStart)
        guard let best = ends.values.max(by: { $0.score < $1.score || ($0.score == $1.score && $0.verse > $1.verse) })
        else { return nil }

        // Just ahead of where he was: the usual case, so it needs less.
        if let current = currentIndex {
            let near = ends.values
                .filter { (current...current + 2).contains($0.verse) }
                .max { $0.score < $1.score || ($0.score == $1.score && $0.verse > $1.verse) }
            if let near, near.score >= best.score - 2,
               near.evidence >= Threshold.follow, near.freshEvidence >= Threshold.fresh {
                guard near.verse > current else {
                    matchedLastPhrase = true
                    return nil
                }
                guard near.landingEvidence >= Threshold.landing else { return nil }
                return move(to: near, kind: .forward)
            }
        }
        guard best.evidence >= Threshold.locate, best.freshEvidence >= Threshold.fresh,
              best.verse != currentIndex
        else { return nil }
        let rival = ends.values.filter { abs($0.verse - best.verse) > 1 }.map(\.score).max() ?? 0
        guard best.score - rival >= Threshold.margin else { return nil }
        let kind: Place.Kind = switch currentIndex {
        case nil: .located
        case let current? where (current + 1...current + 2).contains(best.verse): .forward
        default: .jumped
        }
        return move(to: best, kind: kind)
    }

    private mutating func move(to end: End, kind: Place.Kind) -> Place {
        matchedLastPhrase = true
        currentIndex = end.verse
        let verse = verses[end.verse]
        let place = Place(chapter: verse.chapter, verse: verse.verse, evidence: end.evidence, kind: kind)
        self.place = place
        return place
    }

    // MARK: Search

    /// What to ask the ESV search for, from the latest finished words
    /// (newest last): the distinctive words of the last 14, then the last
    /// four and the first four on their own, since a single misheard word
    /// sinks a search for all of them. Empty when the words are too few or
    /// too plain to be worth a request, or sound like someone talking
    /// rather than reading.
    public static func searchQueries(recent: [String]) -> [String] {
        let window = Array(recent.filter { !fillers.contains($0) }.suffix(14))
        guard window.count >= 8, !window.contains(where: talkWords.contains) else { return [] }
        var content: [String] = []
        for word in window where weight(of: word) != .stop && word.count >= 3
            && word.allSatisfy(\.isLetter) && !content.contains(word) {
            content.append(word)
        }
        // At least five words carrying meaning, three of them distinctive.
        guard content.count >= 5, content.filter({ weight(of: $0) == .distinctive }).count >= 3 else { return [] }
        var queries = [content.joined(separator: " ")]
        if content.count >= 6 { queries.append(content.suffix(4).joined(separator: " ")) }
        if content.count >= 8 { queries.append(content.prefix(4).joined(separator: " ")) }
        return queries
    }

    /// Picks the verse the heard words come from out of a search's results,
    /// or nil when none fits well or two different places fit about as
    /// well (the Gospels often say the same thing twice).
    public static func bestSearchHit(
        heard: [String], results: [(reference: BibleReference, text: String)]
    ) -> (reference: BibleReference, evidence: Double)? {
        let heard = heard.filter { !fillers.contains($0) }
        var scored: [(reference: BibleReference, score: Double, evidence: Double)] = []
        for result in results {
            let tokens = tokens(for: [BibleVerse(chapter: result.reference.chapter, verse: result.reference.startVerse ?? 1, text: result.text)])
            let best = align(heard, tokens, freshFrom: 0).values.max { $0.score < $1.score }
            if let best { scored.append((result.reference, best.score, best.evidence)) }
        }
        guard let top = scored.max(by: { $0.score < $1.score }), top.evidence >= Threshold.searchHit else { return nil }
        func neighbours(_ a: BibleReference, _ b: BibleReference) -> Bool {
            a.book == b.book && a.chapter == b.chapter && abs((a.startVerse ?? 0) - (b.startVerse ?? 0)) <= 1
        }
        let rival = scored.filter { !neighbours($0.reference, top.reference) }.map(\.score).max() ?? 0
        guard top.score - rival >= Threshold.searchMargin else { return nil }
        return (top.reference, top.evidence)
    }

    // MARK: Slides

    /// The slide whose verses include this one, from the slides' names
    /// ("Romans 8:28–30", as ScriptureSlideBuilder names them). The first
    /// such slide, so a verse split over two slides starts at its beginning.
    public static func slideIndex(book: BibleBook, chapter: Int, verse: Int, slideNames: [String]) -> Int? {
        slideNames.firstIndex { name in
            guard let range = BibleReference.parse(name), range.book == book,
                  let start = range.startVerse else { return false }
            let first = (range.chapter, start)
            let last = (range.endChapter ?? range.chapter, range.endVerse ?? start)
            return (chapter, verse) >= first && (chapter, verse) <= last
        }
    }

    // MARK: Alignment

    struct Token: Sendable {
        var word: String
        var weight: Weight
        var verse: Int
    }

    enum Weight: Sendable {
        case stop, common, distinctive

        var score: Double {
            switch self {
            case .stop: 0.4
            case .common: 1
            case .distinctive: 2
            }
        }
        var evidence: Double {
            switch self {
            case .stop: 0
            case .common: 0.5
            case .distinctive: 1
            }
        }
    }

    /// The best alignment ending in each verse.
    struct End: Sendable {
        var score: Double
        var evidence: Double
        var freshEvidence: Double
        var landingEvidence: Double
        /// Index into `verses` of the last content word matched.
        var verse: Int
    }

    private struct Cell {
        var score = 0.0
        var evidence = 0.0
        var freshEvidence = 0.0
        var landingEvidence = 0.0
        var verse = -1
    }

    static func tokens(for verses: [BibleVerse]) -> [Token] {
        verses.enumerated().flatMap { index, verse in
            words(verse.text).map { Token(word: $0, weight: weight(of: $0), verse: index) }
        }
    }

    /// Smith–Waterman over heard words × chapter words. Only alignments
    /// ending on a word from the newest phrase (`freshFrom` on) count: the
    /// question is where he is now, not where he was.
    static func align(_ heard: [String], _ tokens: [Token], freshFrom: Int) -> [Int: End] {
        guard !heard.isEmpty, !tokens.isEmpty else { return [:] }
        var previous = [Cell](repeating: Cell(), count: tokens.count + 1)
        var ends: [Int: End] = [:]
        for (row, word) in heard.enumerated() {
            var current = [Cell](repeating: Cell(), count: tokens.count + 1)
            let fresh = row >= freshFrom
            for column in 1...tokens.count {
                let token = tokens[column - 1]
                var best = Cell()

                let diagonal = previous[column - 1]
                let likeness = LyricFollower.likeness(word, token.word)
                let counts = token.weight == .stop ? likeness >= 0.9 : likeness >= 0.5
                if counts {
                    var cell = diagonal
                    cell.score += token.weight.score * likeness
                    let gained = token.weight.evidence * (likeness >= 0.75 ? 1 : 0.5)
                    if gained > 0 {
                        cell.evidence += gained
                        if fresh { cell.freshEvidence += gained }
                        cell.landingEvidence = token.verse == cell.verse ? cell.landingEvidence + gained : gained
                        cell.verse = token.verse
                    }
                    if cell.score > best.score { best = cell }
                } else if diagonal.score > 0 {
                    var cell = diagonal
                    cell.score -= 0.6
                    if cell.score > best.score { best = cell }
                }
                // A heard word that isn't in the text.
                var extra = previous[column]
                extra.score -= 0.6
                if extra.score > best.score { best = extra }
                // A word in the text the recognizer dropped; small words drop most.
                var dropped = current[column - 1]
                dropped.score -= token.weight == .stop ? 0.2 : 0.6
                if dropped.score > best.score { best = dropped }

                current[column] = best
                if fresh, best.verse >= 0, best.score > 0, best.score > (ends[best.verse]?.score ?? 0) {
                    ends[best.verse] = End(
                        score: best.score, evidence: best.evidence, freshEvidence: best.freshEvidence,
                        landingEvidence: best.landingEvidence, verse: best.verse)
                }
            }
            previous = current
        }
        return ends
    }

    // MARK: Words

    /// Lowercased words with contractions spelled out ("don't" → "do not")
    /// and numbers as digits ("twelve" and "12" alike), so the recognizer's
    /// way of writing speech and the Bible's way of writing text meet.
    public static func words(_ text: String) -> [String] {
        var text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: "[’‘`]", with: "'", options: .regularExpression)
        for (pattern, replacement) in contractions {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let plain = text
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .flatMap { $0 == "cannot" ? ["can", "not"] : [String($0)] }
        return SpokenReference.mergeNumberWords(plain)
    }

    private static let contractions: [(String, String)] = [
        (#"\bwon't\b"#, "will not"), (#"\bcan't\b"#, "can not"), (#"\bshan't\b"#, "shall not"),
        (#"\bain't\b"#, "is not"), (#"n't\b"#, " not"), (#"\blet's\b"#, "let us"),
        (#"'ll\b"#, " will"), (#"'re\b"#, " are"), (#"'ve\b"#, " have"), (#"'m\b"#, " am"),
        (#"\b(it|that|there|here|what|he|she|who|where|how)'s\b"#, "$1 is"),
    ]

    static func weight(of word: String) -> Weight {
        if stopWords.contains(word) || word.allSatisfy(\.isNumber) { return .stop }
        if commonWords.contains(word) { return .common }
        // Plurals and -ed/-ing forms of the common words are common too.
        for suffix in ["s", "es", "ed", "d", "ing"] where word.hasSuffix(suffix) {
            if commonWords.contains(String(word.dropLast(suffix.count))) { return .common }
        }
        return .distinctive
    }

    /// Words that place nothing: they're in every verse and every sentence.
    static let stopWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "but", "by", "can", "could", "did", "do", "does", "done", "even",
        "every", "for", "from", "had", "has", "hath", "have", "he", "her", "hers", "him", "his", "how", "i",
        "if", "in", "into", "is", "it", "its", "just", "let", "may", "me", "might", "more", "most", "much",
        "must", "my", "no", "nor", "not", "now", "o", "of", "oh", "on", "one", "or", "our", "out", "over",
        "said", "saith", "say", "says", "shall", "she", "should", "so", "some", "than", "that", "the", "thee",
        "their", "them", "then", "there", "these", "they", "thou", "thy", "this", "those", "to", "unto", "up",
        "upon", "us", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom",
        "whose", "why", "will", "with", "would", "ye", "yet", "you", "your", "yours",
    ]

    /// Words in scripture that sermons also use all the time: they count,
    /// but for half.
    static let commonWords: Set<String> = [
        "god", "lord", "jesus", "christ", "father", "spirit", "holy", "people", "man", "men", "thing", "things",
        "come", "came", "go", "went", "know", "knew", "see", "saw", "day", "good", "make", "made", "give",
        "gave", "take", "took", "life", "live", "love", "loved", "way", "time", "heart", "world", "word",
        "words", "great", "like", "many", "other", "own", "tell", "told", "think", "want", "church", "today",
        "first", "well", "here", "back", "only", "brother", "brothers", "name", "faith", "grace",
    ]

    /// Sounds between words, dropped before matching.
    static let fillers: Set<String> = ["um", "uh", "er", "ah", "hmm", "mm", "erm"]

    /// Words people say and scripture doesn't: a window with one of these is
    /// someone talking, so it isn't searched.
    static let talkWords: Set<String> = [
        "gonna", "wanna", "gotta", "okay", "ok", "guys", "kinda", "sorta", "stuff", "yeah", "alright",
        "basically", "actually", "literally", "maybe", "anyway", "folks",
    ]
}

/// Keeps scripture searches inside the ESV API's limits (60 a minute, 1,000
/// an hour, 5,000 a day): one request every few seconds at most, a daily
/// ceiling under theirs, and backing off when the API says too many.
public struct ScriptureSearchPacer: Sendable {
    public var minimumInterval: TimeInterval = 4
    /// Below the API's 5,000 a day, so passages said by reference (which use
    /// the same allowance) still load late in a long day.
    public var dailyLimit = 3000

    private var lastRequest: Date?
    private var blockedUntil: Date?
    private var backoff: TimeInterval = 0
    private var day = ""
    private var dayCount = 0

    public init() {}

    /// How long until the next request may go, or nil when today's
    /// allowance is spent.
    public func wait(at now: Date) -> TimeInterval? {
        if Self.dayKey(now) == day, dayCount >= dailyLimit { return nil }
        var ready = lastRequest.map { $0.addingTimeInterval(minimumInterval) } ?? now
        if let blockedUntil { ready = max(ready, blockedUntil) }
        return max(0, ready.timeIntervalSince(now))
    }

    public mutating func recordRequest(at now: Date) {
        lastRequest = now
        let key = Self.dayKey(now)
        if key != day { day = key; dayCount = 0 }
        dayCount += 1
    }

    /// A request answered normally: any backoff is over.
    public mutating func succeeded() {
        backoff = 0
    }

    /// The API answered 429. Waits what it asks (Retry-After), else a
    /// minute, doubling each time it happens again, up to an hour.
    public mutating func rateLimited(at now: Date, retryAfter: TimeInterval?) {
        backoff = min(max(backoff * 2, 60), 3600)
        blockedUntil = now.addingTimeInterval(max(retryAfter ?? 0, backoff))
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
