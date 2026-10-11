import Foundation

/// Follows a song from what's being sung. Each slide's lyrics become a word
/// sequence; recent transcript words are matched against the current slide,
/// the next one, and every other slide (for skipped sections, repeated
/// choruses and spontaneous jumps). It recommends advancing when the singer
/// has reached the next slide's opening words, or has finished the current
/// slide's last line — with a confidence the operator can watch.
public struct LyricFollower: Sendable {

    public struct Decision: Equatable, Sendable {
        public var slideIndex: Int
        public var confidence: Double
        public var reason: Reason

        public enum Reason: Equatable, Sendable { case nextSlideStarted, currentSlideFinished, jump }
    }

    public private(set) var slides: [[String]]
    /// Words heard recently, newest last.
    public private(set) var heard: [String] = []
    public var windowSize = 8
    /// How sure a jump to a non-adjacent slide must be.
    public var jumpThreshold = 0.8
    public var advanceThreshold = 0.6

    public init(slideTexts: [String]) {
        slides = slideTexts.map(Self.words)
    }

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .split(separator: " ").map(String.init)
            .filter { !$0.isEmpty }
    }

    public mutating func hear(_ text: String) {
        heard += Self.words(text)
        if heard.count > 40 { heard.removeFirst(heard.count - 40) }
    }

    public mutating func reset() { heard = [] }

    /// What to do given the slide that's live now; nil means stay.
    public func decision(current: Int) -> Decision? {
        guard !heard.isEmpty, slides.indices.contains(current) else { return nil }
        let recent = Array(heard.suffix(windowSize))

        let next = current + 1
        if slides.indices.contains(next) {
            let opening = Array(slides[next].prefix(max(3, min(6, slides[next].count))))
            let score = Self.similarity(recent.suffix(opening.count + 2).map { $0 }, opening, anchoredEnd: false)
            if score >= advanceThreshold {
                return Decision(slideIndex: next, confidence: score, reason: .nextSlideStarted)
            }
            let ending = Array(slides[current].suffix(4))
            let finished = Self.similarity(Array(recent.suffix(ending.count)), ending, anchoredEnd: true)
            if finished >= 0.85 {
                return Decision(slideIndex: next, confidence: finished * 0.9, reason: .currentSlideFinished)
            }
        }

        // A jump elsewhere: the recent words match another slide much better.
        guard recent.count >= 4 else { return nil }
        var best: (index: Int, score: Double)?
        for (index, slide) in slides.enumerated() where index != current && index != next && slide.count >= 3 {
            let score = Self.coverage(recent, slide)
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        let here = Self.coverage(recent, slides[current])
        if let best, best.score >= jumpThreshold, best.score > here + 0.25 {
            return Decision(slideIndex: best.index, confidence: best.score, reason: .jump)
        }
        return nil
    }

    /// How much of `pattern` appears, in order, within `heard` — tolerant of
    /// misrecognized and dropped words. 0…1.
    public static func similarity(_ heard: [String], _ pattern: [String], anchoredEnd: Bool) -> Double {
        guard !heard.isEmpty, !pattern.isEmpty else { return 0 }
        // Longest common subsequence with fuzzy word equality.
        var table = Array(repeating: Array(repeating: 0, count: pattern.count + 1), count: heard.count + 1)
        for i in 1...heard.count {
            for j in 1...pattern.count {
                table[i][j] = alike(heard[i - 1], pattern[j - 1])
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        var score = Double(table[heard.count][pattern.count]) / Double(pattern.count)
        if anchoredEnd, let last = heard.last, let end = pattern.last, !alike(last, end) {
            score *= 0.7
        }
        return score
    }

    /// How many of the heard words belong, in order, to this slide. 0…1.
    public static func coverage(_ heard: [String], _ slide: [String]) -> Double {
        guard !heard.isEmpty else { return 0 }
        return similarity(slide, heard, anchoredEnd: false)
    }

    static func alike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.hasPrefix(String(b.prefix(4))) || editDistance(a, b) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
