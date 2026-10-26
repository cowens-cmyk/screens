import Foundation

/// Where the slide on the screens sits after its presentation changed under
/// it. The auto-advance loop counts from the live slide's place in the run
/// of slides; when slides are added or taken out ahead of it, that place has
/// to follow the slide, or the loop skips one or shows one twice.
public enum LiveOccurrence {
    /// The live slide's new place: where it appears in `ids`, the nearest to
    /// where it was when it appears more than once (an arrangement repeats a
    /// chorus). Nil when it's no longer there.
    public static func follow(slideID: String, from occurrence: Int?, in ids: [String]) -> Int? {
        let places = ids.indices.filter { ids[$0] == slideID }
        guard let first = places.first else { return nil }
        guard let occurrence else { return first }
        return places.min { abs($0 - occurrence) < abs($1 - occurrence) } ?? first
    }
}
