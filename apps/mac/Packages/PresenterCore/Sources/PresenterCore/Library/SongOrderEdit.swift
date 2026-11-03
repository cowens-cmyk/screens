import Foundation

/// The edits the Song Order editor makes to a list of section ids, kept
/// apart from the view so the drop arithmetic is tested.
public enum SongOrderEdit {

    /// A section dropped from the song's sections into the order, before
    /// `index` (the end when nil or past it).
    public static func inserting(_ sectionID: String, before index: Int?, in order: [String]) -> [String] {
        var out = order
        out.insert(sectionID, at: min(max(index ?? out.count, 0), out.count))
        return out
    }

    /// A block of the order dragged to sit before `index` (the end when nil).
    public static func moving(from: Int, before index: Int?, in order: [String]) -> [String] {
        guard order.indices.contains(from) else { return order }
        let target = index ?? order.count
        guard target != from, target != from + 1 else { return order }
        var out = order
        let block = out.remove(at: from)
        out.insert(block, at: min(max(from < target ? target - 1 : target, 0), out.count))
        return out
    }

    public static func removing(at index: Int, in order: [String]) -> [String] {
        guard order.indices.contains(index) else { return order }
        var out = order
        out.remove(at: index)
        return out
    }

    /// The order a song plays with no arrangement: each run of slides in
    /// one section, in slide order.
    public static func baseOrder(of presentation: Presentation) -> [String] {
        let known = Set((presentation.sections ?? []).map(\.id))
        var out: [String] = []
        for slide in presentation.slides {
            guard let id = slide.sectionId, known.contains(id), out.last != id else { continue }
            out.append(id)
        }
        return out
    }

    /// Drag payloads: a section from the palette, or a block of the order.
    public static func sectionPayload(_ sectionID: String) -> String { "songorder.section::\(sectionID)" }
    public static func blockPayload(_ index: Int) -> String { "songorder.block::\(index)" }

    public enum Payload: Equatable {
        case section(String)
        case block(Int)
    }

    public static func payload(_ text: String) -> Payload? {
        let parts = text.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "songorder.section": return .section(parts[1])
        case "songorder.block": return Int(parts[1]).map(Payload.block)
        default: return nil
        }
    }
}
