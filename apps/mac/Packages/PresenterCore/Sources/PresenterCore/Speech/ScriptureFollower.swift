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
        /// How far into the verse's words he is, 0…1: a verse long enough
        /// to need two slides moves to the second partway through.
        public var progress: Double
    }

    /// The thresholds, together, so the tests and the app read the same ones.
    public enum Threshold {
        /// Finding a passage, or moving anywhere but just ahead.
        public static let locate = 5.0
        /// Putting a passage found from reading on screen without being asked.
        public static let show = 6.0
        /// The same over another presentation the operator chose (sermon
        /// notes): it must be a reading, not a verse quoted from memory, so
        /// more words and `streak` phrases in a row.
        public static let showOverOther = 8.0
        public static let streak = 2
        /// Reading on into the next verse or two.
        public static let follow = 3.0
        /// Words in the newest phrase that must match before anything moves
        /// (one distinctive word, or two common ones), so an old match can't
        /// carry commentary along with it.
        public static let fresh = 1.0
        /// Distinctive words in order in the verse being moved into, all
        /// from the newest phrase (a misheard one counts half): an old match
        /// carried through commentary never moves into the next verse on one
        /// shared word.
        public static let landing = 2.0
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
    /// Finished phrases in a row that fit the text in order: two or more
    /// is someone reading, where one could be a verse quoted in passing.
    public private(set) var streak = 0
    /// How far into the current verse's words he is, 0…1.
    public private(set) var progress = 0.0

    private let tokens: [Token]
    /// Each verse's first token and its number of tokens.
    private let verseStart: [Int]
    private let verseLength: [Int]
    private var heard: [String] = []
    private var currentIndex: Int?

    /// `verse` is where reading is expected to start (a spoken reference),
    /// or nil to wait until the reading itself says where it is.
    public init(verses: [BibleVerse], at verse: Int? = nil) {
        self.verses = verses
        let tokens = Self.tokens(for: verses)
        self.tokens = tokens
        var start = [Int](repeating: 0, count: verses.count)
        var length = [Int](repeating: 0, count: verses.count)
        for (index, token) in tokens.enumerated().reversed() {
            start[token.verse] = index
            length[token.verse] += 1
        }
        verseStart = start
        verseLength = length
        if let verse, let index = verses.firstIndex(where: { $0.verse == verse }) {
            currentIndex = index
            place = Place(chapter: verses[index].chapter, verse: verse, evidence: 0, kind: .located, progress: 0)
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
        let wasMatching = matchedLastPhrase
        matchedLastPhrase = false
        let new = new.filter { !Self.fillers.contains($0) }
        guard !new.isEmpty, !tokens.isEmpty else { return nil }
        heard = Array((heard + new).suffix(Self.memory))
        let freshStart = heard.count - min(new.count, heard.count)
        let ends = Self.align(heard, tokens, freshFrom: freshStart)
        let result = decide(ends)
        // A phrase that fit after one that fit, in order, extends the streak;
        // a jump back starts a new one.
        if matchedLastPhrase {
            streak = wasMatching && result?.kind != .jumped ? streak + 1 : 1
        } else {
            streak = 0
        }
        return result
    }

    private mutating func decide(_ ends: [Int: End]) -> Place? {
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
                    progress = fraction(of: near)
                    if let place { self.place?.progress = max(place.progress, progress) }
                    return nil
                }
                guard near.landingFresh >= Threshold.landing else { return nil }
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
        guard kind == .located || best.landingFresh >= Threshold.landing else { return nil }
        return move(to: best, kind: kind)
    }

    private mutating func move(to end: End, kind: Place.Kind) -> Place {
        matchedLastPhrase = true
        currentIndex = end.verse
        progress = fraction(of: end)
        let verse = verses[end.verse]
        let place = Place(
            chapter: verse.chapter, verse: verse.verse, evidence: end.evidence, kind: kind, progress: progress)
        self.place = place
        return place
    }

    private func fraction(of end: End) -> Double {
        let length = verseLength[end.verse]
        guard length > 0 else { return 0 }
        return min(1, max(0, Double(end.token - verseStart[end.verse] + 1) / Double(length)))
    }

    // MARK: Search

    /// What to ask the ESV search for, from the latest finished words
    /// (newest last): the distinctive words of the last 14, then, only if
    /// that finds nothing, the last four on their own, since a single
    /// misheard word sinks a search for all of them. Never more than two
    /// per phrase: the ESV allowance is shared with every passage shown.
    /// Empty when the words are too few or too plain to be worth a request,
    /// or sound like someone talking rather than reading.
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

    /// The slide holding this verse, from the slides' names ("Romans
    /// 8:28–30", as ScriptureSlideBuilder names them). A verse too long for
    /// one slide continues on the next ones under the same name; `progress`
    /// (how far into the verse he is) picks among them by their share of
    /// the verse's words (`wordCounts`, one per slide, else equal shares).
    public static func slideIndex(
        book: BibleBook, chapter: Int, verse: Int, progress: Double = 0,
        slideNames: [String], wordCounts: [Int]? = nil
    ) -> Int? {
        let holding = slideNames.indices.filter { index in
            guard let range = BibleReference.parse(slideNames[index]), range.book == book,
                  let start = range.startVerse else { return false }
            let first = (range.chapter, start)
            let last = (range.endChapter ?? range.chapter, range.endVerse ?? start)
            return (chapter, verse) >= first && (chapter, verse) <= last
        }
        guard let first = holding.first else { return nil }
        guard holding.count > 1 else { return first }
        let shares = holding.map { index in
            Double(max(1, wordCounts.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? 1))
        }
        let total = shares.reduce(0, +)
        var reached = 0.0
        for (offset, share) in shares.enumerated() {
            reached += share / total
            // Moves on a little before the end of a part: phrases arrive a
            // moment after they're said, and the next part should be up as
            // he reaches it.
            if progress < reached - 0.1 * share / total || offset == holding.count - 1 { return holding[offset] }
        }
        return holding.last
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
        /// Distinctive words in this verse matched from the newest phrase.
        var landingFresh: Double
        /// Index into `verses` of the last content word matched, and of
        /// that word in the chapter.
        var verse: Int
        var token: Int
    }

    private struct Cell {
        var score = 0.0
        var evidence = 0.0
        var freshEvidence = 0.0
        var landingFresh = 0.0
        var verse = -1
        var token = -1
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
                        let landed = fresh && token.weight == .distinctive ? (likeness >= 0.75 ? 1.0 : 0.5) : 0
                        cell.landingFresh = token.verse == cell.verse ? cell.landingFresh + landed : landed
                        cell.verse = token.verse
                        cell.token = column - 1
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
                        landingFresh: best.landingFresh, verse: best.verse, token: best.token)
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

/// Keeps scripture searches well inside the ESV API's limits (60 a minute,
/// 1,000 an hour, 5,000 a day), which passages shown by reference share.
/// Requests are spaced at least `minimumInterval` apart and drawn from a
/// small allowance that refills slowly, so a sermon of ordinary talk spends
/// it evenly (about five a minute) rather than using an hour's worth in the
/// first half and then finding nothing for the rest. Hard ceilings per hour
/// and per day sit under the API's, and a 429 backs off.
public struct ScriptureSearchPacer: Sendable {
    public var minimumInterval: TimeInterval = 6
    public var hourlyLimit = 300
    public var dailyLimit = 1500
    /// The allowance: up to `burst` requests at once, one more every
    /// `refill` seconds.
    public var burst = 10.0
    public var refill: TimeInterval = 12

    private var tokens: Double?
    private var tokensAt: Date?
    private var lastRequest: Date?
    private var lastHour: [Date] = []
    private var blockedUntil: Date?
    private var backoff: TimeInterval = 0
    private var day = ""
    private var dayCount = 0

    public init() {}

    /// How long until the next search may go, or nil when the hour's or
    /// day's ceiling is reached and nothing will free up soon enough to wait
    /// for (the day's).
    public func wait(at now: Date) -> TimeInterval? {
        if Self.dayKey(now) == day, dayCount >= dailyLimit { return nil }
        var ready = lastRequest.map { $0.addingTimeInterval(minimumInterval) } ?? now
        if let blockedUntil { ready = max(ready, blockedUntil) }
        let hour = lastHour.filter { now.timeIntervalSince($0) < 3600 }
        if hour.count >= hourlyLimit, let oldest = hour.first {
            ready = max(ready, oldest.addingTimeInterval(3600))
        }
        let available = allowance(at: now)
        if available < 1 { ready = max(ready, now.addingTimeInterval((1 - available) * refill)) }
        return max(0, ready.timeIntervalSince(now))
    }

    /// A search sent: spaced and drawn from the allowance.
    public mutating func recordRequest(at now: Date) {
        lastRequest = now
        count(at: now)
    }

    /// A request that goes regardless (a passage someone asked for, or the
    /// chapter of one just found): never held back, but counted, so the
    /// searches after it slow down instead.
    public mutating func count(at now: Date) {
        tokens = allowance(at: now) - 1
        tokensAt = now
        lastHour = lastHour.filter { now.timeIntervalSince($0) < 3600 } + [now]
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

    private func allowance(at now: Date) -> Double {
        guard let tokens, let tokensAt else { return burst }
        return min(burst, tokens + now.timeIntervalSince(tokensAt) / refill)
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
