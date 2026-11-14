import Foundation

/// What the plan preloader (the app's PlanPreloader) reads into memory and
/// how much room it gives itself: the parts that need no library, media
/// engine or screen, so they can be tested.
public enum PlanPreloadPlan {

    // MARK: What a plan needs

    /// The media a plan uses, each once, in the order the plan reaches it:
    /// the stage layouts first (any of them can go up at any time), then
    /// item by item. A presentation brings its themes' media (the themes it
    /// draws with and the ones its livestream lower thirds come from), its
    /// backgrounds, its slides' media (a slide's livestream lower-third
    /// picture among them) and the media its type's actions fire. An item's
    /// own actions (its macros) bring theirs. `streamThemeIDs` are themes the
    /// livestream may draw from whatever the item, such as the series.
    public static func mediaIDs(
        items: [ServiceItem], decks: [String: Presentation], themes: (String) -> Theme?,
        stageLayouts: [ConfidenceLayout], streamThemeIDs: [String] = [],
        typeActions: (Presentation) -> [SlideAction] = { _ in [] }
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ ids: some Sequence<String>) {
            for id in ids where !id.isEmpty && seen.insert(id).inserted { ordered.append(id) }
        }
        for layout in stageLayouts { add(MediaReferences.ids(inObjects: layout.objects).sorted()) }
        for item in items {
            switch item.itemKind {
            case .media:
                add([item.refId])
            case .presentation:
                guard let deck = decks[item.refId] else { continue }
                for id in themeIDs(of: deck, themes: themes) {
                    if let theme = themes(id) { add(MediaReferences.ids(in: theme).sorted()) }
                }
                add([deck.background?.mediaId, deck.backgroundFill?.mediaId].compactMap { $0 })
                for section in deck.sections ?? [] { add([section.background?.mediaId].compactMap { $0 }) }
                for slide in deck.slides { add(MediaReferences.ids(in: slide).sorted()) }
                add(MediaReferences.ids(inActions: typeActions(deck)).sorted())
            default:
                break
            }
            add(MediaReferences.ids(inActions: item.actions).sorted())
        }
        for id in streamThemeIDs {
            if let theme = themes(id) { add(MediaReferences.ids(in: theme).sorted()) }
        }
        return ordered
    }

    /// Every theme a presentation draws with: its own, its slides', the
    /// ones its livestream lower thirds come from, and the ones those
    /// themes send the livestream to (their lower-third theme and the
    /// designs picked per category), so the stream's design is read before
    /// the slide that shows it.
    public static func themeIDs(of deck: Presentation, themes: (String) -> Theme? = { _ in nil }) -> [String] {
        var ids = [deck.themeId, deck.streamThemeId ?? ""]
        for slide in deck.slides {
            ids.append(slide.themeId ?? "")
            ids.append(slide.streamDesign?.themeId ?? "")
        }
        var seen = Set<String>()
        var direct = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        for id in direct {
            for named in themes(id)?.streamThemeReferences ?? [] where !named.isEmpty && seen.insert(named).inserted {
                direct.append(named)
            }
        }
        return direct
    }

    /// The audio items a plan plays, in plan order, each once.
    public static func audioIDs(items: [ServiceItem]) -> [String] {
        var seen = Set<String>()
        return items.filter { $0.itemKind == .audio && !$0.refId.isEmpty }
            .map(\.refId).filter { seen.insert($0).inserted }
    }

    // MARK: How much room

    public struct Budget: Equatable, Sendable {
        /// Bytes of decoded pictures held ready to draw.
        public var pictures: Int
        /// Bytes of video and audio files read through, so the system keeps
        /// them in its file cache.
        public var files: Int
    }

    /// How much of the Mac's memory the plan may take. On 16 GB or less it
    /// stays as careful as it always was: an eighth for pictures, a quarter
    /// for files read through, the start of the plan first. Above that a
    /// quarter each, so a big Mac holds a whole plan: 8 GB of pictures on
    /// 32 GB, 16 GB on 64 GB, where a 300-picture message is about 2.5 GB.
    /// Pictures are real memory (the GPU's copy of each one); files read
    /// through are the system's cache, which it gives back by itself.
    public static func budget(physicalMemory: UInt64) -> Budget {
        let memory = Int(clamping: physicalMemory)
        if physicalMemory <= 16 << 30 {
            return Budget(pictures: memory / 8, files: memory / 4)
        }
        return Budget(pictures: memory / 4, files: memory / 4)
    }

    /// How many video players wait ready on their first frame, and over how
    /// many plan items (nil: the whole plan). Below 32 GB as before: the
    /// item on screen and the next two, six players at most. From 32 GB,
    /// every video in the plan (its looping backgrounds, video items and
    /// the videos its actions fire), up to 12, nearest first: the operator
    /// jumps around the plan, and a player standing by is cheap (measured on
    /// an M1 Max with twelve standing by, 1080p H.264 and HEVC: under 1 MB of
    /// the app's footprint and nothing measurable in the system's decoder
    /// services per player; StandbyCostBenchmark in MediaEngine). Twelve is
    /// what was measured, and the booth's plan has twelve videos. Kernel
    /// memory for hardware decoding shows in neither number, and running
    /// short of decoder sessions would show as a live video failing to
    /// start, so raising this needs a run with that many standing by while
    /// several others play.
    public struct Players: Equatable, Sendable {
        public var limit: Int
        public var itemsAhead: Int?
    }

    public static func players(physicalMemory: UInt64) -> Players {
        physicalMemory >= 32 << 30 ? Players(limit: 12, itemsAhead: nil) : Players(limit: 6, itemsAhead: 3)
    }

    /// The memory a picture takes decoded: four bytes a pixel, 1920×1080
    /// when the library never recorded its size.
    public static func pictureBytes(width: Int?, height: Int?) -> Int {
        max(width ?? 1920, 1) * max(height ?? 1080, 1) * 4
    }
}
