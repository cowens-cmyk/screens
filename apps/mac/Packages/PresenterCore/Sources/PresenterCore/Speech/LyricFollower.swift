import Foundation

/// Follows a song from what's being sung, the way an operator does: it keeps
/// its place word by word through the arranged slides and says when the next
/// slide should go up.
///
/// The arranged slides (repeated choruses included) are laid end to end as
/// one word sequence, and every heard word moves an alignment along it:
/// dynamic programming over every place in the song at once, like a score
/// follower. A heard word can match the next word, skip a word or two the
/// recogniser dropped, be an extra word (an ad-lib, a misheard word, the
/// leader talking) or start somewhere else: later in this slide, the next
/// slide, or any slide at all when the band goes back to the chorus. A jump
/// costs more the less expected it is, so a repeated chorus resolves to the
/// copy nearest the singer, and a slide's rarer words count for more than
/// "the", "you" and "and", so common words never pull the place away.
///
/// The live slide anchors the place. Whenever it changes, by the operator or
/// by an advance, the alignment restarts there, with room for the singer
/// still finishing the slide before. Going back needs the singer to have
/// started that slide from its top and sung several words of it, so one held
/// or repeated line never flips the slides back and forth.
///
/// Pure and deterministic: no clocks and no audio. LiveAssist feeds it the
/// recogniser's text and decides what to do with its decisions.
public struct LyricFollower: Sendable {

    public struct Decision: Equatable, Sendable {
        /// The arranged slide to put up next.
        public var slideIndex: Int
        public var confidence: Double
        public var reason: Reason

        public enum Reason: Equatable, Sendable {
            /// The singer has started the next slide's first line.
            case nextSlideStarted
            /// The singer is on the last word of the live slide.
            case currentSlideFinished
            /// The singer went somewhere other than the next slide.
            case jump
        }
    }

    /// Where the singer is: an arranged slide, and how many of its words
    /// have been sung.
    public struct Position: Equatable, Sendable {
        public var slideIndex: Int
        public var word: Int
        public var wordCount: Int
    }

    /// Scores and limits. Gains and costs are in the same units: a distinctive
    /// word that matches is worth about 2.
    public struct Tuning: Sendable {
        /// An extra word that matches nothing (ad-lib, misheard, talking).
        public var insertion = 0.9
        /// A filler ("oh", "yeah", "whoa") that matches nothing: ad-libs
        /// cost little and don't count against how well it's following.
        public var fillerInsertion = 0.3
        /// A heard word taking the place of a slide word it doesn't match.
        public var substitution = 1.0
        /// Each slide word the recogniser dropped.
        public var skip = 0.8
        public var maxSkip = 2
        /// Starting elsewhere in the slide the singer is on.
        public var jumpWithinSlide = 1.8
        /// Leaving the rest of the slide for the next one.
        public var jumpToNext = 2.2
        /// Any other slide; each slide further away adds a little more, a
        /// little more again going back, so of two copies of a chorus the
        /// nearer one wins.
        public var jumpElsewhere = 3.5
        public var jumpPerSlideForward = 0.1
        public var jumpPerSlideBack = 0.15
        /// Coming in partway through a slide, per word in.
        public var jumpPerWordIn = 0.3

        /// The next slide goes up with this many words of the live slide
        /// still to sing (1: while the last word is sung).
        public var leadWords = 1
        /// Words of the live slide that must have been heard before its end counts.
        public var wordsToFinish = 3
        /// Words of the next slide that make it the next slide.
        public var wordsToEnter = 2
        /// Words, from its top, that make any other slide a jump.
        public var wordsToJump = 4
        /// A jump starts within this many words of the slide's top.
        public var jumpEntry = 2
        /// Below this, a decision isn't worth showing.
        public var minimumConfidence = 0.3
        /// How sharply score margins turn into confidence.
        public var sharpness = 2.0

        public init() {}
    }

    struct Token: Sendable {
        let word: String
        /// Index into `vocabulary`.
        let kind: Int
        let weight: Double
        let slide: Int
        let offset: Int
    }

    /// The best path ending at one place in the song, and what it saw on the way.
    struct State: Sendable {
        var score: Double
        /// The arranged slide of the last word sung (or the anchor slide).
        var slide: Int
        /// Words of `slide` this path matched, and their combined weight.
        var matched: Int
        var evidence: Double
        /// Where in `slide` the path came in.
        var entry: Int
        /// One bit per heard word, newest lowest: did it match?
        var recent: UInt16
        var heard: Int

        static let unreachable = State(
            score: -.infinity, slide: 0, matched: 0, evidence: 0, entry: 0, recent: 0, heard: 0)
        var reachable: Bool { score > -.infinity }
    }

    public let tuning: Tuning
    public let slideCount: Int
    /// The live slide, as an arranged index.
    public private(set) var live: Int
    /// The latest decision, fresh from the words just heard; nil means stay.
    public private(set) var decision: Decision?
    /// What to show the operator: the latest decision, kept while the
    /// singing still supports it.
    public private(set) var suggestion: Decision?
    public private(set) var position: Position?

    let tokens: [Token]
    /// The song's distinct words.
    let vocabulary: [String]
    let slideStart: [Int]
    let slideEnd: [Int]
    /// Slides with the same words share a key, so the same lyric in two
    /// places counts as one place for confidence.
    let textKey: [Int]
    let nextWorded: [Int?]
    let previousWorded: [Int?]

    /// Settled words, and the in-progress utterance on top of them.
    var committed: [State]
    var current: [State]
    /// Words of the in-progress utterance that came before the last re-anchor
    /// (or were already settled), so revisions don't count them twice.
    var skipWords = 0
    var utteranceWords = 0
    /// The first words of the utterance in progress, to tell a revision of it
    /// from a new one that arrived without the old one being settled.
    var utteranceHead: [String] = []
    /// How alike each recently heard word is to each of the song's words;
    /// partial results repeat the same words many times over.
    var likenessCache: [String: [Double]] = [:]

    public init(slideTexts: [String], live: Int = 0, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        slideCount = slideTexts.count
        let slideWords = slideTexts.map(Self.words)

        // Weight by rarity across the distinct slides, so a chorus sung four
        // times doesn't make its own words common.
        var counts: [String: Int] = [:]
        for words in Set(slideWords) { for word in words { counts[word, default: 0] += 1 } }
        var tokens: [Token] = []
        var kinds: [String: Int] = [:]
        var vocabulary: [String] = []
        var starts: [Int] = []
        var ends: [Int] = []
        for (slide, words) in slideWords.enumerated() {
            starts.append(tokens.count)
            for (offset, word) in words.enumerated() {
                let weight = Self.stopWords.contains(word) ? 0.6 : 1.3 + 0.9 / Double(max(1, counts[word] ?? 1))
                let kind = kinds[word] ?? vocabulary.count
                if kind == vocabulary.count { kinds[word] = kind; vocabulary.append(word) }
                tokens.append(Token(word: word, kind: kind, weight: weight, slide: slide, offset: offset))
            }
            ends.append(tokens.count)
        }
        self.tokens = tokens
        self.vocabulary = vocabulary
        slideStart = starts
        slideEnd = ends
        var keys: [[String]: Int] = [:]
        textKey = slideWords.map { words in
            if let key = keys[words] { return key }
            keys[words] = keys.count
            return keys.count - 1
        }
        nextWorded = slideWords.indices.map { index in
            slideWords.indices.dropFirst(index + 1).first { !slideWords[$0].isEmpty }
        }
        previousWorded = slideWords.indices.map { index in
            slideWords.indices.prefix(index).last { !slideWords[$0].isEmpty }
        }
        let clamped = min(max(0, live), max(0, slideTexts.count - 1))
        self.live = clamped
        committed = []
        current = []
        committed = anchored(at: clamped)
        current = committed
    }

    // MARK: Feeding it

    /// The live slide changed (the operator, or an advance): listen from there.
    public mutating func liveChanged(to index: Int) {
        guard slideCount > 0 else { return }
        live = min(max(0, index), slideCount - 1)
        committed = anchored(at: live)
        current = committed
        // Words of the utterance in progress were sung before this slide went up.
        skipWords = utteranceWords
        decision = nil
        suggestion = nil
        position = nil
    }

    /// The recogniser's text for the utterance in progress. Each partial
    /// result replaces the one before; a final one settles it.
    public mutating func hear(_ text: String, isFinal: Bool = true) {
        guard !tokens.isEmpty else { return }
        let words = Self.words(text)
        let head = Array(words.prefix(2))
        let shared = min(head.count, utteranceHead.count)
        if shared > 0, head.prefix(shared) != utteranceHead.prefix(shared) {
            // A new utterance: what was heard of the last one stands.
            committed = current
            skipWords = 0
        }
        utteranceHead = isFinal ? [] : head
        let fresh = words.count > skipWords ? Array(words[skipWords...]) : []
        if likenessCache.count > 400 { likenessCache.removeAll() }
        for word in fresh where likenessCache[word] == nil {
            likenessCache[word] = vocabulary.map { Self.likeness(word, $0) }
        }
        if isFinal {
            committed = run(fresh, from: committed)
            current = committed
            skipWords = 0
            utteranceWords = 0
        } else {
            utteranceWords = words.count
            // A long unbroken utterance: settle all but its last words, which
            // are the only ones the recogniser still revises.
            if fresh.count > 24 {
                let settled = fresh.count - 12
                committed = run(Array(fresh.prefix(settled)), from: committed)
                skipWords += settled
                current = run(Array(fresh.dropFirst(settled)), from: committed)
            } else {
                current = run(fresh, from: committed)
            }
        }
        decide()
    }

    // MARK: Alignment

    /// The place before any word is heard: the top of the live slide most
    /// likely, anywhere in it a little less (the slide went up late), and the
    /// last few words of the slide before (it went up early).
    func anchored(at slide: Int) -> [State] {
        var states = Array(repeating: State.unreachable, count: tokens.count + 1)
        guard slideStart.indices.contains(slide) else { return states }
        let start = slideStart[slide]
        for offset in 0...(slideEnd[slide] - start) {
            let score = offset == 0 ? 0 : -(0.5 + 0.15 * Double(offset))
            states[start + offset] = State(
                score: score, slide: slide, matched: 0, evidence: 0, entry: offset, recent: 0, heard: 0)
        }
        if let previous = previousWorded[slide] {
            let length = slideEnd[previous] - slideStart[previous]
            for back in 1...min(3, length) {
                let cursor = slideEnd[previous] - back
                states[cursor] = State(
                    score: -(0.3 + 0.2 * Double(back)), slide: previous, matched: 0, evidence: 0,
                    entry: length - back, recent: 0, heard: 0)
            }
        }
        return states
    }

    func run(_ words: [String], from states: [State]) -> [State] {
        words.reduce(states) { step($1, from: $0) }
    }

    /// One heard word. `states[j]` is the best path that has sung the first
    /// j words of the song.
    func step(_ word: String, from states: [State]) -> [State] {
        guard let bestIndex = states.indices.max(by: { states[$0].score < states[$1].score }),
              states[bestIndex].reachable
        else { return states }
        let best = states[bestIndex]
        let reference = best.slide
        let alike = likenessCache[word] ?? vocabulary.map { Self.likeness(word, $0) }

        // Staying put: the word was extra.
        let filler = Self.fillers.contains(word)
        var next = states.map { state -> State in
            guard state.reachable else { return state }
            var stayed = state
            if filler {
                stayed.score -= tuning.fillerInsertion
            } else {
                stayed.score -= tuning.insertion
                stayed.recent <<= 1
                stayed.heard += 1
            }
            return stayed
        }
        for (index, token) in tokens.enumerated() {
            let likeness = alike[token.kind]
            let matched = likeness >= 0.5
            let gain = matched ? token.weight * likeness : -tuning.substitution
            var score = -Double.infinity
            var from = best
            for skipped in 0...tuning.maxSkip where index - skipped >= 0 {
                let previous = states[index - skipped]
                guard previous.reachable else { continue }
                let candidate = previous.score + gain - tuning.skip * Double(skipped)
                if candidate > score { score = candidate; from = previous }
            }
            let jump = best.score + gain - jumpCost(to: token.slide, offset: token.offset, from: reference)
            if jump > score { score = jump; from = best }
            guard score > next[index + 1].score else { continue }
            let same = from.slide == token.slide
            next[index + 1] = State(
                score: score, slide: token.slide,
                matched: (same ? from.matched : 0) + (matched ? 1 : 0),
                evidence: (same ? from.evidence : 0) + (matched ? gain : 0),
                entry: same ? from.entry : token.offset,
                recent: from.recent << 1 | (matched ? 1 : 0),
                heard: from.heard + 1)
        }
        let top = next.map(\.score).max() ?? 0
        if top.isFinite { for index in next.indices where next[index].reachable { next[index].score -= top } }
        return next
    }

    func jumpCost(to slide: Int, offset: Int, from reference: Int) -> Double {
        let base: Double
        if slide == reference {
            base = tuning.jumpWithinSlide
        } else if nextWorded.indices.contains(reference), slide == nextWorded[reference] {
            base = tuning.jumpToNext
        } else if slide > reference {
            base = tuning.jumpElsewhere + tuning.jumpPerSlideForward * Double(slide - reference)
        } else {
            base = tuning.jumpElsewhere + tuning.jumpPerSlideBack * Double(reference - slide)
        }
        return base + min(1.5, tuning.jumpPerWordIn * Double(offset))
    }

    // MARK: Deciding

    private enum Group: Hashable { case liveHead, liveTail, text(Int) }

    private func remaining(_ state: State, at cursor: Int) -> Int { slideEnd[state.slide] - cursor }

    private func isLiveText(_ slide: Int) -> Bool { textKey[slide] == textKey[live] }

    private func group(_ state: State, at cursor: Int) -> Group {
        guard isLiveText(state.slide) else { return .text(textKey[state.slide]) }
        return state.matched >= 1 && remaining(state, at: cursor) <= tuning.leadWords ? .liveTail : .liveHead
    }

    private mutating func decide() {
        let states = current
        guard let bestIndex = states.indices.max(by: { states[$0].score < states[$1].score }),
              states[bestIndex].reachable, states[bestIndex].heard > 0
        else {
            decision = nil
            return
        }
        let best = states[bestIndex]
        position = Position(
            slideIndex: best.slide, word: bestIndex - slideStart[best.slide],
            wordCount: slideEnd[best.slide] - slideStart[best.slide])

        // How likely each place is: the best path into each group of places,
        // turned into shares of one.
        var top: [Group: Double] = [:]
        for (cursor, state) in states.enumerated() where state.reachable {
            let key = group(state, at: cursor)
            top[key] = max(top[key] ?? -.infinity, state.score)
        }
        let weights = top.mapValues { exp(tuning.sharpness * $0) }
        let total = weights.values.reduce(0, +)
        func share(_ key: Group) -> Double { (weights[key] ?? 0) / total }

        let window = min(8, best.heard)
        let quality = Double((best.recent & UInt16((1 << window) - 1)).nonzeroBitCount) / Double(window)

        decision = fresh(best: best, at: bestIndex, quality: quality, share: share)
        if let decision {
            suggestion = decision
        } else if let kept = suggestion {
            let support = kept.reason == .currentSlideFinished
                ? share(.liveTail) + share(.text(textKey[kept.slideIndex]))
                : share(.text(textKey[kept.slideIndex]))
            if support < 0.25 {
                suggestion = nil
            } else {
                suggestion?.confidence = min(kept.confidence, support * quality)
            }
        }
    }

    private func fresh(
        best: State, at cursor: Int, quality: Double, share: (Group) -> Double
    ) -> Decision? {
        let length = slideEnd[best.slide] - slideStart[best.slide]
        var made: Decision?
        if isLiveText(best.slide) {
            // On the live slide's last words: the next slide can go up.
            let target = live + 1
            let needed = min(tuning.wordsToFinish, max(1, length / 2))
            guard target < slideCount, best.matched >= needed,
                  remaining(best, at: cursor) <= tuning.leadWords
            else { return nil }
            let targetShare = isLiveText(target) ? 0 : share(.text(textKey[target]))
            var confidence = (share(.liveTail) + targetShare) * quality * 0.9
            // Nothing to sing on it (a blank or an instrumental): the operator decides.
            if slideEnd[target] == slideStart[target] { confidence = min(confidence, 0.45) }
            made = Decision(slideIndex: target, confidence: confidence, reason: .currentSlideFinished)
        } else {
            let next = nextWorded[live]
            let isNext = next.map { textKey[$0] == textKey[best.slide] } ?? false
            let target = isNext ? next ?? best.slide : best.slide
            var needed = isNext ? tuning.wordsToEnter : tuning.wordsToJump
            if best.slide == previousWorded[live] { needed += 1 }
            needed = min(needed, length)
            guard best.matched >= needed, best.evidence >= 1.2 * Double(needed),
                  isNext || best.entry <= tuning.jumpEntry
            else { return nil }
            let confidence = share(.text(textKey[best.slide])) * quality
            made = Decision(
                slideIndex: target, confidence: confidence,
                reason: isNext ? .nextSlideStarted : .jump)
        }
        guard let made, made.confidence >= tuning.minimumConfidence else { return nil }
        return made
    }

    // MARK: Words

    public static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: "['’‘`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            // Repeat marks on a slide ("x2", "(repeat)") are never sung.
            .filter { !$0.isEmpty && $0 != "repeat" && $0.wholeMatch(of: /x\d+|\d+x/) == nil }
    }

    /// Words that say little about where in a song the singer is.
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "he", "his", "i", "im", "in",
        "is", "it", "its", "me", "my", "no", "of", "oh", "on", "or", "our", "so", "that", "the", "their",
        "there", "this", "to", "us", "we", "who", "will", "with", "yeah", "you", "your", "youre",
    ]

    /// Sounds singers add between lines.
    static let fillers: Set<String> = [
        "oh", "ooh", "oo", "whoa", "woah", "yeah", "yea", "hey", "ah", "aah", "la", "na", "mm", "hmm", "uh", "um",
        "eh", "ho", "ha",
    ]

    /// Words a recogniser swaps for each other when they're sung.
    static let soundAlike: [String: Int] = {
        let groups: [[String]] = [
            ["to", "too", "two"], ["there", "their", "theyre"], ["your", "youre"], ["know", "no"],
            ["new", "knew"], ["hear", "here"], ["son", "sun"], ["one", "won"], ["whole", "hole"],
            ["praise", "prays", "preys"], ["reign", "rain", "rein"], ["right", "write", "rite"],
            ["see", "sea"], ["be", "bee"], ["for", "four", "fore"], ["through", "threw", "thru"],
            ["i", "eye"], ["by", "buy", "bye"], ["our", "hour", "are"], ["heal", "heel"],
            ["wear", "where"], ["peace", "piece"], ["hallelujah", "alleluia", "halleluiah"],
            ["ill", "isle", "aisle"], ["weak", "week"], ["night", "knight"], ["morning", "mourning"],
        ]
        var map: [String: Int] = [:]
        for (index, group) in groups.enumerated() { for word in group { map[word] = index } }
        return map
    }()

    /// How alike a heard word is to a slide word, 0…1.
    static func likeness(_ heard: String, _ word: String) -> Double {
        if heard == word { return 1 }
        if let a = soundAlike[heard], a == soundAlike[word] { return 0.9 }
        let shorter = min(heard.count, word.count)
        if shorter >= 3, stem(heard) == stem(word) { return 0.85 }
        // Edit distance is at least the difference in length.
        guard shorter >= 4, abs(heard.count - word.count) <= 2 else { return 0 }
        let distance = editDistance(heard, word)
        if distance == 1 { return 0.75 }
        if distance == 2, shorter >= 6 { return 0.55 }
        if shorter >= 5, heard.prefix(4) == word.prefix(4) { return 0.5 }
        return 0
    }

    private static func stem(_ word: String) -> Substring {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return word.dropLast(suffix.count)
        }
        return Substring(word)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
