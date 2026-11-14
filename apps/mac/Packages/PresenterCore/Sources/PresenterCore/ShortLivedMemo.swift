import Foundation

/// Answers kept for a moment: each key is worked out once per `lifetime`
/// and per generation, then answered from memory. For questions a view
/// body asks over and over whose answer only changes now and then, such as
/// whether a media file is on this Mac, which otherwise stats the disk for
/// every tile on every pass of the plan page.
public struct ShortLivedMemo<Key: Hashable, Value> {
    public let lifetime: TimeInterval
    private var generation: Int?
    private var startedAt: TimeInterval = 0
    private var answers: [Key: Value] = [:]

    public init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    /// The answer for `key`: remembered when this generation asked within
    /// `lifetime` of `now`, otherwise `compute()`'s, which is remembered.
    public mutating func value(
        for key: Key, generation: Int, now: TimeInterval, _ compute: () -> Value
    ) -> Value {
        if self.generation != generation || now - startedAt > lifetime || now < startedAt {
            self.generation = generation
            startedAt = now
            answers.removeAll(keepingCapacity: true)
        }
        if let known = answers[key] {
            return known
        }
        let value = compute()
        answers[key] = value
        return value
    }
}
