import CoreGraphics
import Foundation

/// Where a picture or video dragged over a presentation's slides lands, from
/// the media bin or the Finder. Between two slides (near a tile's edge, or in
/// the gap between tiles) it becomes a new slide there; on a slide it becomes
/// that slide's background, as it always has.
public enum SlideDropPlacement {

    /// A drop's place among the grid's tiles, by their index in the grid.
    public enum Target: Equatable, Sendable {
        case before(Int)
        case onto(Int)
        case after(Int)
    }

    /// The narrowest edge that counts as "beside" a tile: the strip the grid
    /// has always used for inserting before a slide.
    public static let minimumEdge: CGFloat = 26

    /// How much of a tile's width each edge takes, so a large tile still
    /// leaves room to land between slides without aiming for a thin strip.
    public static let edgeShare: CGFloat = 0.2

    /// Media over a tile, `x` from its leading edge: near the leading edge
    /// goes before it, near the trailing edge after it, anywhere else onto it.
    public static func target(overTile index: Int, x: CGFloat, width: CGFloat) -> Target {
        guard width > 0 else { return x < minimumEdge ? .before(index) : .onto(index) }
        // A third each at most, so even a small tile keeps a middle to drop on.
        let edge = min(max(minimumEdge, width * edgeShare), width / 3)
        if x < edge { return .before(index) }
        if x > width - edge { return .after(index) }
        return .onto(index)
    }

    /// A drop in the space around the tiles: the gap between two, under a
    /// row, or past the last tile of a row. It goes beside the nearest tile
    /// in the nearest row. `tiles` is each laid-out tile's frame by index,
    /// in the same space as `point`; nil when none are laid out.
    public static func target(among tiles: [Int: CGRect], at point: CGPoint) -> Target? {
        guard !tiles.isEmpty else { return nil }
        // Tiles in a row share a top edge; rounding absorbs layout fractions.
        let rows = Dictionary(grouping: tiles, by: { $0.value.minY.rounded() })
            .sorted { $0.key < $1.key }
            .map { row in row.value.sorted { $0.value.minX < $1.value.minX } }
        // The row whose band holds the point: each row reaches halfway into
        // the gap below it; the last reaches down without end.
        var chosen = rows[rows.count - 1]
        for (number, row) in rows.enumerated() where number + 1 < rows.count {
            let bottom = row.map(\.value.maxY).max() ?? 0
            let nextTop = rows[number + 1][0].value.minY
            if point.y < (bottom + nextTop) / 2 {
                chosen = row
                break
            }
        }
        if let tile = chosen.first(where: { point.x < $0.value.midX }) {
            return .before(tile.key)
        }
        return chosen.last.map { .after($0.key) }
    }

    /// Where new slides go in the presentation for a place in the grid: the
    /// grid shows the arranged slides, so the place is named by the slide it
    /// sits beside. `slideIDs` is the grid's slides in order. Nil for a drop
    /// onto a slide, which doesn't add one.
    public enum Anchor: Equatable, Sendable {
        case before(String)
        case after(String)
        /// At the end: an empty presentation, or a place past the slides.
        case end
    }

    public static func anchor(for target: Target, in slideIDs: [String]) -> Anchor? {
        switch target {
        case .onto:
            return nil
        case .before(let index):
            if slideIDs.indices.contains(index) { return .before(slideIDs[index]) }
            return slideIDs.last.map(Anchor.after) ?? .end
        case .after(let index):
            if slideIDs.indices.contains(index) { return .after(slideIDs[index]) }
            return slideIDs.last.map(Anchor.after) ?? .end
        }
    }

    /// Puts slides at an anchor, taking the section of the slide they land
    /// beside so they show under the same heading.
    public static func insert(_ slides: [Slide], at anchor: Anchor, in presentation: inout Presentation) {
        let (index, neighbor) = landing(at: anchor, in: presentation)
        let landing = slides.map { slide in
            var slide = slide
            slide.sectionId = neighbor?.sectionId
            return slide
        }
        presentation.slides.insert(contentsOf: landing, at: index)
    }

    /// The section slides inserted at `anchor` join. When it repeats in the
    /// arrangement, they show in every repeat, so the grid asks first.
    public static func sectionId(at anchor: Anchor, in presentation: Presentation) -> String? {
        landing(at: anchor, in: presentation).neighbor?.sectionId
    }

    private static func landing(at anchor: Anchor, in presentation: Presentation) -> (index: Int, neighbor: Slide?) {
        switch anchor {
        case .before(let id):
            let index = presentation.slides.firstIndex { $0.id == id } ?? presentation.slides.count
            let neighbor = presentation.slides.indices.contains(index) ? presentation.slides[index] : presentation.slides.last
            return (index, neighbor)
        case .after(let id):
            let found = presentation.slides.firstIndex { $0.id == id }
            return (found.map { $0 + 1 } ?? presentation.slides.count,
                    found.map { presentation.slides[$0] } ?? presentation.slides.last)
        case .end:
            return (presentation.slides.count, presentation.slides.last)
        }
    }
}

/// New slides from pictures and videos: one each, with it as the background,
/// the same whether it was dropped between slides, picked from the Media
/// Library or brought from the Finder.
public enum MediaSlideBuilder {
    public struct Made: Equatable, Sendable {
        public var slides: [Slide]
        /// Lower thirds dropped for slides already in the presentation:
        /// slide id → the picture's media id.
        public var existingLowerThirds: [String: String]

        public init(slides: [Slide] = [], existingLowerThirds: [String: String] = [:]) {
            self.slides = slides
            self.existingLowerThirds = existingLowerThirds
        }
    }

    /// A picture named for one of the others, or for a slide in `existing`
    /// ("Slide01_LowerThird" for "Slide01_Wide"), is that slide's livestream
    /// lower third rather than a slide of its own.
    public static func make(
        _ items: [MediaItem], sectionId: String? = nil,
        existing: [(id: String, name: String)] = [],
        newID: () -> String = { UUID().uuidString }
    ) -> Made {
        let plan = LowerThirdPairing.plan(
            dropped: items.map { .init(id: $0.id, name: $0.name, isImage: $0.mediaKind == .image) },
            existing: existing)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slides = plan.slideMedia.compactMap { byID[$0] }.map { item in
            Slide(
                id: newID(),
                name: item.name,
                objects: [],
                background: CueMedia.droppedAsNewSlide(for: item),
                sectionId: sectionId,
                streamDesign: plan.lowerThirds[item.id].map(StreamDesign.lowerThirdImage))
        }
        return Made(slides: slides, existingLowerThirds: plan.existingSlides)
    }

    /// Whether something from the Finder can make slides: a picture, a
    /// video, or a folder of them. Anything else (a PDF, a Keynote deck,
    /// music) adds no slide, so the grid doesn't offer to take it.
    public static func makesSlides(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        let category = MediaLibraryCategory.forImportedFile(url)
        return category == .images || category == .videos
    }
}
