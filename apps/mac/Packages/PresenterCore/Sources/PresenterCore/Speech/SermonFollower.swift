import Foundation

/// Follows a sermon through its slides from what the pastor says. Unlike a
/// song, a sermon isn't read word for word: the pastor reads a point, then
/// talks around it, comes to the next one. So each slide is matched by the
/// words that set it apart from the others (its point, its quote, the text
/// read off its picture), against the last few sentences heard, and the
/// next slide needs less to go up than a jump ahead or back.
///
/// Pure and deterministic: no clocks, no audio. Feed it final phrases.
public struct SermonFollower: Sendable {

    public struct Match: Equatable, Sendable {
        public var slideIndex: Int
        /// 0…1.
        public var confidence: Double
        public var reason: String
    }

    public struct Tuning: Sendable {
        /// How many recent words are matched against the slides.
        public var window = 45
        /// Evidence (summed word weights) a slide needs before it's suggested.
        public var suggest = 4.0
        /// Evidence the next slide needs to go up by itself.
        public var advanceNext = 6.0
        /// Evidence any other slide needs to go up by itself.
        public var jump = 10.0
        /// How far the best slide must lead the runner-up.
        public var margin = 2.5
        /// Phrases in a row a jump must win before it goes up.
        public var jumpStreak = 2
        public init() {}
    }

    public let slideCount: Int
    public private(set) var live: Int?
    public private(set) var suggestion: Match?
    public private(set) var decision: Match?

    private let tuning: Tuning
    private let slideWords: [Set<String>]
    private let slidePairs: [Set<String>]
    private let weights: [String: Double]
    private var heard: [String] = []
    private var streak: (index: Int, count: Int)?

    /// `slideTexts` is what each slide says, its text and what's read off
    /// its pictures; a slide with no words is never matched.
    public init(slideTexts: [String], live: Int?, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        slideCount = slideTexts.count
        self.live = live
        let tokenized = slideTexts.map(Self.words)
        slideWords = tokenized.map { Set($0) }
        slidePairs = tokenized.map { words in Set(zip(words, words.dropFirst()).map { "\($0) \($1)" }) }
        // Words on many slides (the series name on every graphic) tell
        // slides apart less than a word only one slide has.
        var counts: [String: Int] = [:]
        for words in slideWords { for word in words { counts[word, default: 0] += 1 } }
        let total = Double(max(slideTexts.count, 1))
        weights = counts.mapValues { count in
            1 + log(total / Double(count))
        }
    }

    /// The operator (or the follower's own advance) put up another slide:
    /// listen from there, and forget what led to the last one.
    public mutating func liveChanged(to index: Int?) {
        live = index
        heard = []
        streak = nil
        suggestion = nil
        decision = nil
    }

    public mutating func hear(_ text: String) {
        heard = Array((heard + Self.words(text)).suffix(tuning.window))
        let scores = (0..<slideCount).map(score)
        let ranked = scores.indices.filter { $0 != live }.sorted { scores[$0] > scores[$1] }
        guard let best = ranked.first, scores[best] >= tuning.suggest else {
            suggestion = nil
            decision = nil
            streak = nil
            return
        }
        // The live slide counts as a rival: still talking about the point on
        // screen isn't a reason to move on.
        let rival = max(ranked.dropFirst().first.map { scores[$0] } ?? 0, live.map { scores[$0] } ?? 0)
        let lead = scores[best] - rival
        let isNext = live.map { best == $0 + 1 } ?? (best == 0)
        let confidence = min(1, scores[best] / (isNext ? tuning.advanceNext : tuning.jump) * 0.7 + min(lead, 6) / 20)
        let reason = isNext ? "next" : "jump"
        suggestion = lead >= tuning.margin / 2 ? Match(slideIndex: best, confidence: confidence, reason: reason) : nil

        streak = streak?.index == best ? (best, streak!.count + 1) : (best, 1)
        let enough = isNext
            ? scores[best] >= tuning.advanceNext
            : scores[best] >= tuning.jump && (streak?.count ?? 0) >= tuning.jumpStreak
        // The next slide is where a sermon usually goes, so it wins a near
        // tie that a jump would have to win outright.
        let needed = isNext ? tuning.margin * 0.6 : tuning.margin
        decision = enough && lead >= needed ? Match(slideIndex: best, confidence: confidence, reason: reason) : nil
    }

    /// How strongly what was just said points at a slide: each of its
    /// distinctive words heard, more for words heard side by side as they
    /// are on the slide (a point being read out).
    private func score(_ index: Int) -> Double {
        let words = slideWords[index]
        guard !words.isEmpty else { return 0 }
        var total = 0.0
        for word in Set(heard) where words.contains(word) {
            total += weights[word] ?? 1
        }
        let pairs = Set(zip(heard, heard.dropFirst()).map { "\($0) \($1)" })
        total += Double(pairs.intersection(slidePairs[index]).count) * 1.5
        // A long slide has more words to hit by chance.
        return total / max(1, sqrt(Double(words.count) / 8))
    }

    // MARK: Words

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those", "as",
        "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "our",
        "their", "so", "do", "does", "did", "not", "no", "yes", "have", "has", "had", "will", "would", "can",
        "could", "just", "what", "who", "how", "when", "where", "why", "there", "here", "then", "than",
        "about", "into", "out", "up", "down", "all", "some", "any", "one", "like", "go", "going", "get", "got",
        "know", "really", "very", "uh", "um", "okay", "right", "say", "said", "see", "now", "let", "lets",
    ]

    /// Lowercased content words, roughly stemmed so "dreams" meets "dream".
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map(stem)
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
