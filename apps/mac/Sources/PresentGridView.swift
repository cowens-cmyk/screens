import PresenterCore
import RenderEngine
import SlideScene
import os
import SwiftUI

struct PresentGridView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presentationID: String
    let arrangementId: String?

    var contextID: String? = nil

    var serviceID: String? = nil
    var serviceItem: ServiceItem? = nil

    @HotDefault("slideGrid.roundedCorners") private var roundedCorners = true
    @HotDefault("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @HotDefault("slideGrid.legibleText") private var legibleText = false
    @HotDefault(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback
    @FocusState private var focused: Bool

    @State private var deleteRequests = 0

    @State private var clipboardRequests = SlideClipboardRequests()

    @State private var previewArrangementID: String?

    private var fireContext: String { contextID ?? presentationID }

    private var effectiveArrangementID: String? {
        serviceItem != nil ? arrangementId : previewArrangementID
    }

    private var stripSelection: Binding<String?> {
        Binding(
            get: { effectiveArrangementID },
            set: { newValue in
                if let serviceID, let serviceItem {
                    model.setServiceItemArrangement(
                        serviceID, itemID: serviceItem.id, arrangementID: newValue
                    )
                } else {
                    previewArrangementID = newValue
                }
            }
        )
    }

    var body: some View {
        let _ = model.listVersion

        if let presentation = model.presentation(presentationID) {
            let theme = model.theme(presentation.themeId)

            let slides = model.arrangedSlides(presentation, arrangementId: effectiveArrangementID)
            ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(presentation)
                if presentation.sections?.isEmpty == false {
                    ArrangementStrip(
                        model: model, presentation: presentation,
                        selection: stripSelection,
                        onJump: { pill in
                            let starts = SlideSceneBuilder.arrangementBlockStarts(
                                for: presentation, arrangementId: effectiveArrangementID
                            )
                            guard starts.indices.contains(pill),
                                  starts[pill] < slides.count else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(
                                    SlideGridBody.tileAnchor(
                                        contextID: fireContext, index: starts[pill]
                                    ),
                                    anchor: .top
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                Divider()
                ScrollView {
                    SlideGridBody(
                        model: model, render: render, controls: controls,
                        presentation: presentation, theme: theme,
                        slides: slides, arrangementId: effectiveArrangementID,
                        contextID: fireContext,
                        roundedCorners: roundedCorners,
                        hideScopedBackgrounds: hideScopedBackgrounds,
                        legibleText: legibleText,
                        chosenAcross: slidesAcross,
                        deleteRequests: deleteRequests,
                        clipboardRequests: clipboardRequests,
                        pastesAtEnd: true,
                        marqueeMargin: 12
                    )
                    .padding(12)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()

                .onPresentFireKeys {
                    fireStep($0, slides, presentation)
                    controls?.noteKeyboardFire()
                }

                .background(KeyboardFireFollow(controls: controls) { revealLive(proxy) })
                // Everything else that puts a slide up: a click, the
                // remote, Anthem, a slide's own timing.
                .background(LiveTileFollow(controls: controls, contextID: fireContext) {
                    followLive(proxy, count: slides.count)
                })

                .onDeleteCommand { deleteRequests += 1 }

                .onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }
            }
            }
            .onAppear { focused = true }
        } else if model.presentationExists(presentationID) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Presentation not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func header(_ presentation: Presentation) -> some View {
        HStack {
            Text(presentation.name)
                .font(.headline)
            if let arrangementId = effectiveArrangementID,
               let name = presentation.arrangements?.first(where: { $0.id == arrangementId })?.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let serviceID, let serviceItem {
                AnthemMismatchBadge(model: model, serviceID: serviceID, itemID: serviceItem.id, labeled: true)
            }
            ShepherdNewerChartBadge(model: model, presentationID: presentation.id)
            SongKeyChip(model: model, controls: controls, presentation: presentation)
            SlideShowChip(model: model, controls: controls, presentation: presentation)
            LyricFollowChip(controls: controls, presentation: presentation)
            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }


    private func revealLive(_ proxy: ScrollViewProxy) {
        if let controls, controls.liveContextID == fireContext, let occurrence = controls.liveOccurrence {
            proxy.scrollTo(SlideGridBody.tileAnchor(contextID: fireContext, index: occurrence), anchor: .center)
        }
    }

    /// A slide of this grid went live some way other than an arrow key
    /// here: the grid scrolls only as far as it takes to show it and the
    /// slide after it, so clicking through a song brings up the next row.
    /// It stays put for a few seconds after the operator scrolls it.
    private func followLive(_ proxy: ScrollViewProxy, count: Int) {
        guard let controls, controls.liveContextID == fireContext,
              let occurrence = controls.liveOccurrence else { return }
        let recorder = InputTrailRecorder.shared
        // An arrow key here already centred it.
        if let key = recorder.sinceKey(), key < PresentFollowRule.clickWindow { return }
        if let scroll = recorder.sinceGridScroll(), scroll < PresentFollowRule.scrollPause,
           (recorder.sinceGridClick() ?? .infinity) > scroll {
            return
        }
        proxy.scrollTo(SlideGridBody.tileAnchor(contextID: fireContext, index: occurrence))
        guard occurrence + 1 < count else { return }
        // After the live tile has settled, so the two don't fight: the
        // next one, which only moves the grid when it's below the edge.
        DispatchQueue.main.async {
            proxy.scrollTo(SlideGridBody.tileAnchor(contextID: fireContext, index: occurrence + 1))
        }
    }

    private func fireStep(_ delta: Int, _ slides: [Slide], _ presentation: Presentation) {
        guard let controls, !slides.isEmpty else { return }

        let settled = delta > 0 && NSEvent.modifierFlags.contains(.option)
        controls.advance(steps: delta, settled: settled) {
            let current = controls.liveContextID == fireContext ? (controls.liveOccurrence ?? -1) : -1
            let next = current < 0 ? (delta > 0 ? 0 : slides.count - 1) : current + delta
            guard slides.indices.contains(next) else { return }
            controls.fire(
                slide: slides[next], in: presentation, arrangementId: effectiveArrangementID,
                contextID: fireContext, occurrence: next
            )
        }
    }
}

@MainActor
enum SlideGridMetrics {
    static let spacing: CGFloat = 12

    static var lastWidths: [String: CGFloat] = [:]

    static var continuousWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: continuousWidthKey)) }
        set {
            if abs(newValue - continuousWidth) >= 1 {
                UserDefaults.standard.set(Double(newValue), forKey: continuousWidthKey)
            }
        }
    }
    static let continuousWidthKey = "slideGrid.continuousWidth"

    /// Two lines under every slide: what the slide is (two lines of it
    /// when there's nothing else to say), then the smaller detail.
    static let labelHeight: CGFloat = 34

    /// The space between a slide and its number and name.
    static let labelGap: CGFloat = 4

    static func tileAspect(for presentation: Presentation) -> CGFloat {
        SlidesAcross.tileAspect(canvas: SlideSceneBuilder.canvasSize(for: presentation))
    }

    static func columns(across count: Int, cellWidth: CGFloat? = nil) -> [GridItem] {
        Array(
            repeating: cellWidth.map { GridItem(.fixed($0), spacing: spacing) }
                ?? GridItem(.flexible(), spacing: spacing),
            count: SlidesAcross.clamped(count)
        )
    }

    static func cell(width: CGFloat, across: Int, aspect: CGFloat) -> CGSize? {
        SlidesAcross.cell(
            width: width, across: across, spacing: spacing,
            aspect: aspect, labelGap: labelGap, labelHeight: labelHeight)
    }
}

@MainActor
enum SlidePasteboard {
    static let type = NSPasteboard.PasteboardType(EditorPaste.slideType)

    static let slidesType = NSPasteboard.PasteboardType(EditorPaste.slidesType)

    static func copy(_ slide: Slide) {
        copy([slide])
    }

    /// Which ⌘C or ⌘X the last copy answered, and whether the next one
    /// adds to it (several items' slides copied by one keypress).
    static var copyGeneration = -1
    static var appendsCopy = false

    /// Counts every ⌘C and ⌘X for the life of the app, so each keypress
    /// has its own number: a page rebuilt by leaving Present starts its own
    /// counts at zero, and a cut never changes the copy count.
    private static var lastRound = 0

    static func nextRound() -> Int {
        lastRound += 1
        return lastRound
    }

    static func copy(_ slides: [Slide]) {
        var slides = slides
        if appendsCopy, let data = NSPasteboard.general.data(forType: slidesType),
           let earlier = try? JSONDecoder().decode([Slide].self, from: data) {
            slides = earlier + slides
        }
        appendsCopy = false
        if let first = slides.first, let data = try? JSONEncoder().encode(first),
           let all = try? JSONEncoder().encode(slides) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: type)
            NSPasteboard.general.setData(all, forType: slidesType)
            SlidePasteboardChanges.shared.count += 1
        }
    }

    static func pasteAll() -> [Slide] {
        if let data = NSPasteboard.general.data(forType: slidesType),
           let slides = try? JSONDecoder().decode([Slide].self, from: data) {
            return slides.map { $0.freshIDCopy() }
        } else {
            return paste().map { [$0] } ?? []
        }
    }

    static var hasSlide: Bool {
        NSPasteboard.general.data(forType: type) != nil
    }

    static func paste() -> Slide? {
        guard let data = NSPasteboard.general.data(forType: type),
              let slide = try? JSONDecoder().decode(Slide.self, from: data)
        else { return nil }
        return slide.freshIDCopy()
    }
}

@MainActor
@Observable
final class SlidePasteboardChanges {
    static let shared = SlidePasteboardChanges()
    var count = 0
}

struct SlideClipboardRequests: Equatable {
    enum Verb { case copy, cut, paste, selectAll, delete }

    var copies = 0
    var cuts = 0
    var pastes = 0
    var selectAlls = 0

    /// The ⌘C or ⌘X every grid is answering (SlidePasteboard.nextRound).
    var round = 0

    @MainActor
    mutating func take(_ verb: Verb) {
        switch verb {
        case .copy:
            round = SlidePasteboard.nextRound()
            copies += 1
        case .cut:
            round = SlidePasteboard.nextRound()
            cuts += 1
        case .paste: pastes += 1
        case .selectAll: selectAlls += 1
        case .delete: break
        }
    }
}

/// Calls `follow` when a different slide of this grid goes live.
private struct LiveTileFollow: View {
    let controls: ServiceControls?
    let contextID: String
    let follow: () -> Void

    var body: some View {
        Color.clear.onChange(of: place) { _, place in
            if place != nil { follow() }
        }
    }

    private var place: Int? {
        controls?.liveContextID == contextID ? controls?.liveOccurrence : nil
    }
}

struct KeyboardFireFollow: View {
    let controls: ServiceControls?
    let reveal: () -> Void

    var body: some View {
        Color.clear.onChange(of: controls?.keyboardFires) { _, _ in reveal() }
    }
}

extension View {

    func onPresentFireKeys(_ step: @escaping (Int) -> Void) -> some View {
        let fire: (Int) -> KeyPress.Result = { direction in
            if NSApp.keyWindow?.firstResponder is NSText {
                return .ignored
            } else {
                step(direction)
                return .handled
            }
        }
        return onKeyPress(.leftArrow) { fire(-1) }
            .onKeyPress(.rightArrow) { fire(1) }
            .onKeyPress(.return) { fire(1) }
            .onKeyPress(.space) { fire(1) }
    }

    /// `deletes` also routes the Delete and Forward Delete keys (lists in
    /// the editor; never the live grid, where a stray key would cost slides).
    func onSlideClipboardKeys(
        active: Bool, deletes: Bool = false, perform action: @escaping (SlideClipboardRequests.Verb) -> Void
    ) -> some View {
        background(SlideClipboardKeyMonitor(active: active, deletes: deletes, action: action))
    }
}

private struct SlideClipboardKeyMonitor: NSViewRepresentable {
    let active: Bool
    var deletes = false
    let action: (SlideClipboardRequests.Verb) -> Void

    final class Coordinator {
        var monitor: Any?
        var deletes = false
        var action: (SlideClipboardRequests.Verb) -> Void = { _ in }
        weak var view: NSView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, let verb = verb(for: event) {
                    action(verb)
                    return nil
                } else {
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func verb(for event: NSEvent) -> SlideClipboardRequests.Verb? {
            let typing = event.window?.firstResponder is NSText || TopBarSearch.blocks(event.window)
            if let window = view?.window, event.window === window, window.isKeyWindow,
               window.attachedSheet == nil, !typing, deletes,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               event.keyCode == 51 || event.keyCode == 117 {
                return .delete
            } else if let window = view?.window, event.window === window, window.isKeyWindow,
               window.attachedSheet == nil, !typing,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": return .copy
                case "x": return .cut
                case "v": return .paste
                case "a": return .selectAll
                default: return nil
                }
            } else {
                return nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        sync(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        sync(context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    private func sync(_ coordinator: Coordinator) {
        coordinator.action = action
        coordinator.deletes = deletes
        if active { coordinator.install() } else { coordinator.remove() }
    }
}

struct SlideGridBody: View {

    static func tileAnchor(contextID: String, index: Int) -> String {
        "slideTile|\(contextID)|\(index)"
    }

    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presentation: Presentation
    let theme: Theme?
    let slides: [Slide]
    let arrangementId: String?
    let contextID: String
    let roundedCorners: Bool
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    /// The stored Slides Across choice; automatic resolves against this
    /// grid's own width.
    let chosenAcross: Int

    private var slidesAcross: Int {
        SlidesAcross.resolved(chosenAcross, width: measuredWidth, spacing: SlideGridMetrics.spacing)
    }

    var deleteRequests = 0

    var clipboardRequests = SlideClipboardRequests()

    var pastesAtEnd = false

    /// Asked when a paste or New Slide comes, instead of `pastesAtEnd`: the
    /// plan page's selection, read then rather than passed in, so moving
    /// the selection doesn't rebuild every grid.
    var pastesAtEndCheck: (() -> Bool)? = nil

    private var hostsPaste: Bool { pastesAtEndCheck?() ?? pastesAtEnd }

    var newSlideContexts: [String] = []

    var buildsRowsNearView = false

    var marqueeMargin: CGFloat = 0

    @State private var gridWidth: CGFloat = 0

    /// Which rows are built as tiles, the rows still to build and where
    /// the grid last was (see buildRows). Each row reads its own flag, so
    /// building a row makes that row and nothing else: as a set in the
    /// grid's state, each row added re-ran the grid and every tile already
    /// in it.
    @State private var rowQueue = RowBuildQueue()

    private var cell: CGSize? {
        SlideGridMetrics.cell(
            width: measuredWidth, across: slidesAcross, aspect: SlideGridMetrics.tileAspect(for: presentation))
    }

    @ViewBuilder
    private func tiles(aspect: CGFloat, cell: CGSize?) -> some View {
        if buildsRowsNearView {
            tileRows(aspect: aspect, cell: cell)
        } else {
            LazyVGrid(columns: SlideGridMetrics.columns(across: slidesAcross, cellWidth: cell?.width), alignment: .leading, spacing: SlideGridMetrics.spacing) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    gridTile(index: index, slide: slide, aspect: aspect)
                        .frame(width: cell?.width, height: cell?.height, alignment: .top)
                }
            }
        }
    }

    private func tileRows(aspect: CGFloat, cell: CGSize?) -> some View {
        let across = SlidesAcross.clamped(slidesAcross)
        return VStack(alignment: .leading, spacing: SlideGridMetrics.spacing) {
            ForEach(SlidesAcross.rows(count: slides.count, across: across), id: \.indices.lowerBound) { row in
                GridRowSwitch(flag: rowQueue.flag(row.indices.lowerBound / across), ready: cell != nil) {
                    HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
                        ForEach(row.indices, id: \.self) { index in
                            if let cell {
                                gridTile(index: index, slide: slides[index], aspect: aspect)
                                    .frame(width: cell.width, height: cell.height, alignment: .top)
                            }
                        }
                    }
                } empty: {
                    HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
                        ForEach(row.indices, id: \.self) { index in
                            placeholderCell(cell: cell, aspect: aspect)
                                .id(Self.tileAnchor(contextID: contextID, index: index))
                        }

                        if cell == nil {
                            ForEach(0 ..< row.fillers, id: \.self) { _ in
                                placeholderCell(cell: nil, aspect: aspect)
                            }
                        }
                    }
                }
            }
            // No Add Slide row in Present: the last tile's + (on hover), its
            // right-click New Slide After…, the item header's Add Slide…
            // and File › New Slide still add one.
        }
    }

    @ViewBuilder
    private func placeholderCell(cell: CGSize?, aspect: CGFloat) -> some View {
        if let cell {
            // A faint slide-shaped box, so rows not built yet (a glide
            // passing them, a fast scroll) read as slides on their way and
            // not as a hole in the page.
            Color.white.opacity(0.045)
                .frame(width: cell.width, height: cell.width / max(aspect, 0.1))
                .clipShape(.rect(cornerRadius: roundedCorners ? CornerStandard.element : 0))
                .frame(width: cell.width, height: cell.height, alignment: .top)
        } else {
            VStack(spacing: SlideGridMetrics.labelGap) {
                Color.clear.aspectRatio(aspect, contentMode: .fit)
                Color.clear.frame(height: SlideGridMetrics.labelHeight)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var measuredWidth: CGFloat {
        gridWidth > 0
            ? gridWidth
            : (SlideGridMetrics.lastWidths[contextID] ?? (buildsRowsNearView ? SlideGridMetrics.continuousWidth : 0))
    }

    /// Acts on where the grid is: its width, its place in the content for
    /// the page's landings, and the rows to build.
    private func placed(_ place: GridPlace) {
        measured(place.width)
        if let cell {
            PresentCardFrames.shared.noteDocGrid(PresentLanding.Grid(
                id: contextID, top: place.docTop,
                rowPitch: cell.height + SlideGridMetrics.spacing,
                across: SlidesAcross.clamped(slidesAcross), count: slides.count))
        }
        rowQueue.place = place
        buildRows(place)
    }

    /// Builds the rows coming near the screen and lets go of those now more
    /// than two screens away (SlidesAcross.rowsToKeep). They used to stay
    /// built for as long as the page was open, so a scroll through the plan
    /// left every tile of every item in the view tree: every pointer move
    /// and scroll tick hit-tested all of them, and anything the tiles watch
    /// re-ran all of them. A row let go is an empty cell of the same size,
    /// so nothing moves; coming back, its pictures come from
    /// ThumbnailStore's caches.
    ///
    /// A row of tiles takes several milliseconds to make, so rows come in
    /// one per frame, nearest the screen first: three or four at once, as a
    /// glide or a fast scroll brought them, was a 20 to 35 ms frame, the
    /// stutter in the middle of a glide. Only a row already on screen is
    /// built at once. While the page glides to a picked item the rows that
    /// matter are the ones it will land on (PageGlide), so those are built
    /// and the items it only passes stay empty cells; the rows around the
    /// landing are filled in once it has landed (rowsAfterGlide).
    private func buildRows(_ place: GridPlace) {
        let across = SlidesAcross.clamped(slidesAcross)
        var keeping = Set(selectedOccurrences.map { $0 / across })
        // What is on screen as the glide leaves stays until it has landed.
        if place.gliding { keeping.formUnion(place.actualKeep) }
        let target = SlidesAcross.rowsToKeep(
            built: rowQueue.built, near: place.gliding ? place.visible : place.near, keep: place.keep,
            selected: keeping)
        rowQueue.target = target
        rowQueue.focus = place.visible
        // Even rows on screen come in at the page's pace, a row a frame:
        // three made at once is a 90 ms frame where three frames of 30
        // fill the screen in the same time and the page keeps moving.
        RowBuildPacer.shared.request(rowQueue)
    }

    /// The glide has landed (or was cut short): back to the rows around
    /// where the grid actually is.
    private func rowsAfterGlide() {
        var place = rowQueue.place
        guard place.gliding else { return }
        place.gliding = false
        place.near = place.actualNear
        place.keep = place.actualKeep
        place.visible = place.actualVisible
        rowQueue.place = place
        buildRows(place)
    }

    private func measured(_ width: CGFloat) {
        if gridWidth != width { gridWidth = width }
        if SlideGridMetrics.lastWidths[contextID] != width { SlideGridMetrics.lastWidths[contextID] = width }
        if buildsRowsNearView { SlideGridMetrics.continuousWidth = width }
    }

    private struct PendingSectionEdit {
        let sectionNames: [String]
        let apply: () -> Void
    }

    @Environment(\.runOnly) private var runOnly


    @State private var pendingEdit: PendingSectionEdit?

    /// Where a drop would land: a line before or after a tile, or a ring
    /// on it. Watched by the one layer that draws it and not by the grid,
    /// so a drag across the tiles doesn't re-run the grid for each one it
    /// passes.
    @State private var dropMarks = GridDropMarks()

    /// The tile a right-click was over, for the grid's one menu.
    @State private var menuPress = SlideGridMenuPress()
    @State private var renamingSlide: Slide?
    @State private var renameText = ""

    @State private var quickEditSlide: Slide?

    @State private var mediaActionTarget: MediaActionTarget?

    @State private var actionEditorSlide: Slide?

    @State private var actionPlacement: ActionPlacement?
    @State private var screensTarget: SlideScreensTarget?
    /// Right-click › Edit Chords… on a slide.
    @State private var chordsSlide: IdentifiedID?
    @Environment(\.openWindow) private var openWindow
    /// Right-click › Make This the Worship Theme… on a song's slide.
    @State private var worshipThemeSlide: Slide?
    @State private var livestreamPrompt: LivestreamPromptRequest?

    @State private var autoAdvanceTarget: AutoAdvanceTarget?

    @State private var selectedOccurrences: Set<Int> = []

    @State private var selectionAnchor: Int?

    /// Each tile's frame in the grid, for drops, the marquee and a tile's
    /// width. Read only in those handlers, so it's kept where SwiftUI
    /// doesn't watch it: as `@State` each tile that came on screen wrote
    /// to it, and every write re-ran the whole grid, every tile with it.
    @State private var tileFrameBox = TileFrameBox()

    /// Worked out from the grid's cell size once that is known: tiles sit
    /// on a regular grid, and a tile that measures itself is one more thing
    /// SwiftUI revisits, for every built tile, on every frame of a scroll.
    /// Only a grid not yet measured asks its tiles.
    private var tileFrames: [Int: CGRect] {
        guard let cell else { return tileFrameBox.frames }
        let across = SlidesAcross.clamped(slidesAcross)
        var frames: [Int: CGRect] = [:]
        frames.reserveCapacity(slides.count)
        for index in slides.indices {
            frames[index] = CGRect(
                x: CGFloat(index % across) * (cell.width + SlideGridMetrics.spacing),
                y: CGFloat(index / across) * (cell.height + SlideGridMetrics.spacing),
                width: cell.width, height: cell.height)
        }
        return frames
    }

    @State private var marqueeRect: CGRect?
    /// The plan page's selection box, when this grid is on the page: a box
    /// dragged anywhere selects this grid's slides under it.
    @Environment(\.pageMarquee) private var pageMarquee
    @Environment(\.actionRouter) private var actionRouter

    private struct MediaActionTarget: Identifiable {
        let pairs: [(slideID: String, actionID: String)]

        var kind: DocumentKind = .media
        var id: String { pairs.map(\.actionID).joined(separator: "|") }
    }

    private struct AutoAdvanceTarget: Identifiable {
        let slideIDs: [String]
        let name: String
        var id: String { slideIDs.joined(separator: "|") }
    }

    private struct ActionPlacement: Identifiable {
        let slideIDs: [String]
        let draft: SlideAction
        var id: String { draft.id }
    }

    @State private var slideShowPresented = false

    @State private var newSlideTarget: NewSlideTarget?

    @State private var mediaSlideTarget: MediaSlideTarget?

    @State private var applyThemeTarget: ApplyThemeTarget?

    @State private var mediaMenuState = MediaCueMenuState()

    private func presentationAutoAdvanceBinding() -> Binding<AutoAdvance?> {
        Binding(
            get: { model.presentation(presentation.id)?.autoAdvance },
            set: { advance in
                model.updatePresentationField(
                    presentation.id, \.autoAdvance, key: "autoAdvance", to: advance, undoLabel: "Slide Show")
                controls?.presentationEdited(presentation.id)
            }
        )
    }

    private var effectiveArrangement: Arrangement? {
        guard let arrangementId, !arrangementId.isEmpty else { return nil }
        return presentation.arrangements?.first { $0.id == arrangementId }
    }

    var body: some View {
        let _ = BodyMeter.tick(.slideGridBody)
        ZStack(alignment: .topLeading) {

            Color.clear
                .contentShape(Rectangle())
                .padding(-marqueeMargin)
                .onTapGesture {
                    clearSelection()
                    pageMarquee?.own(contextID)
                    NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID)
                }
                .gesture(marqueeGesture)
            let aspect = SlideGridMetrics.tileAspect(for: presentation)
            let cell = self.cell
            if presentation.slides.isEmpty {
                emptyDeckArea(aspect: aspect, cell: cell)
            } else {
                tiles(aspect: aspect, cell: cell)
                    // One menu for every tile, built for the tile the
                    // right-click was over (SlideGridMenuPress). None in
                    // run-only (tileMenu checks too, as it always has).
                    .contextMenu { if !runOnly { GridMenuContent(grid: self, press: menuPress) } }
            }
            GridDropMarkLayer(marks: dropMarks) { tileFrames[$0] }
            if let rect = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "slideGrid")
        .background {
            if !runOnly {
                SlideGridAnchor(press: menuPress) { tileFrames }
            }
        }
        .modifier(PageMarqueeFollow(
            pageMarquee: pageMarquee, contextID: contextID, onBox: selectUnder, onOtherOwner: clearSelection))

        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        // The grid's one drop target: its tiles, and the gaps between
        // them, under a row and past the last slide (SlideGridDropDelegate).
        // The grid sits at this frame's top left, so a drop's point is in
        // the tiles' own space.
        .onDrop(of: [.plainText, .fileURL], delegate: SlideGridDropDelegate(
            enabled: !runOnly && !slides.isEmpty,
            tile: { SlideDropPlacement.tile(at: $0, among: tileFrames) },
            gap: { SlideDropPlacement.target(among: tileFrames, at: $0) },
            gapAccepts: { gapAccepts($0) },
            goesBeside: { model.media($0) != nil },
            show: { dropMarks.show($0) },
            dropStarted: { dropMarks.settle() },
            performOnTile: { hit, place, payload in dropOnTile(hit, at: place, payload) },
            performInGap: { place, payload in dropInGap(place, payload) }
        ))
        // Where the grid is, worked out as the page moves but acted on only
        // when something that matters changes: which rows are near the
        // screen, the grid's size, its place in the content. It used to be a
        // GeometryReader whose content re-ran for every grid on the page on
        // every frame of a scroll.
        .onGeometryChange(for: GridPlace.self) { [rowPitch = cell.map { $0.height + SlideGridMetrics.spacing },
                                                  across = SlidesAcross.clamped(slidesAcross),
                                                  count = slides.count, near = buildsRowsNearView] proxy in
            GridPlace.of(proxy, rowPitch: rowPitch, across: across, count: count, buildsNear: near)
        } action: { old, place in
            placed(place)
            if abs(place.height - old.height) > 300 {
                DiagnosticsStore.shared.note(
                    "present.grid",
                    detail: "\(contextID) \(Int(old.height)) → \(Int(place.height)) pt, \(slides.count) slides, width \(Int(measuredWidth))")
            }
        }
        .modifier(PageGlideEndFollow(active: buildsRowsNearView) { rowsAfterGlide() })
        .onChange(of: slides.count) { _, _ in
            clearSelection()
            DropLatency.relaid(count: slides.count)
        }
        .onChange(of: arrangementId) { _, _ in clearSelection() }
        .onChange(of: deleteRequests) { _, _ in deleteSelectedSlides() }
        .onChange(of: clipboardRequests.copies) { _, _ in copySelectedSlides() }
        .onChange(of: clipboardRequests.cuts) { _, _ in
            if copySelectedSlides() { deleteSelectedSlides() }
        }
        .onChange(of: clipboardRequests.pastes) { _, _ in pasteFromKeyboard() }
        .onChange(of: clipboardRequests.selectAlls) { _, _ in selectAllFromKeyboard() }
        .onChange(of: NewSlideRouter.shared.requests) { _, _ in newSlideFromMenu() }
        .sheet(item: $livestreamPrompt) { LivestreamPromptSheet(model: model, request: $0) }
        .sheet(item: $newSlideTarget) { target in
            NewSlideSheet(
                appModel: model, render: render, deckThemeId: presentation.themeId,
                startsWithThemes: target.startsWithThemes
            ) { choice in
                insertNewSlide(choice, after: target.after)
            }
        }
        .sheet(item: $mediaSlideTarget) { target in
            MediaSlidePickerSheet(model: model) { mediaIDs in
                _ = insertMediaSlides(mediaIDs: mediaIDs, at: .before(target.beforeIndex))
            }
        }
        .sheet(item: $applyThemeTarget) { target in
            ApplyThemeSheet(
                appModel: model, render: render, deckThemeId: presentation.themeId,
                scope: applyThemeScope(target.slideIDs ?? [])
            ) { themeId, design in
                let slideIDs = target.slideIDs ?? []

                if Set(slideIDs).isSuperset(of: presentation.slides.map(\.id)) {
                    model.applyTheme(to: presentation.id, themeID: themeId, design: design)
                } else {
                    model.applyTheme(to: presentation.id, slideIDs: slideIDs, themeID: themeId, design: design)
                }
            }
        }
        .modifier(WorshipThemePrompt(model: model, presentation: presentation, slide: $worshipThemeSlide))
        .sheet(item: $chordsSlide) { target in
            ChordEditorSheet(model: model, presentationID: presentation.id, slideID: target.id)
        }
        .sheet(item: $quickEditSlide) { target in
            QuickEditView(
                slide: {
                    model.presentation(presentation.id)?.slides
                        .first { $0.id == target.id }
                },
                write: { objectID, text in
                    model.quickEditText(
                        presentationID: presentation.id, slideID: target.id,
                        objectID: objectID, text: text)
                }
            )
        }
        .sheet(item: $mediaActionTarget) { target in
            LibraryPickerSheet(appModel: model, kind: target.kind) { entry in
                model.updateSlides(presentationID: presentation.id, undoLabel: "Choose Media") { presentation in
                    for pair in target.pairs {
                        guard let slideIndex = presentation.slides.firstIndex(
                            where: { $0.id == pair.slideID }),
                            var actions = presentation.slides[slideIndex].actions,
                            let actionIndex = actions.firstIndex(
                                where: { $0.id == pair.actionID })
                        else { continue }
                        if target.kind == .audio {
                            actions[actionIndex].audioItemId = entry.id
                        } else {
                            actions[actionIndex].mediaId = entry.id
                        }
                        presentation.slides[slideIndex].actions = actions
                    }
                }
                mediaActionTarget = nil
            }
        }
        .sheet(item: $actionEditorSlide) { target in
            SlideActionsSheet(
                model: model, slideName: target.name,
                actions: slideActionsBinding(target.id)
            )
        }
        .sheet(item: $screensTarget) { target in
            SlideScreensSheet(model: model, presentation: presentation, slideIDs: target.slideIDs)
        }
        .sheet(item: $actionPlacement) { placement in
            ActionPlacementSheet(model: model, draft: placement.draft) { action in
                addAction(action, to: placement.slideIDs)
            }
        }
        .sheet(item: $autoAdvanceTarget) { target in
            AutoAdvanceSheet(
                slideName: target.name,
                advance: autoAdvanceBinding(target.slideIDs)
            )
        }
        .sheet(isPresented: $slideShowPresented) {
            AutoAdvanceSheet(
                slideName: presentation.name,
                advance: presentationAutoAdvanceBinding(),
                presentationScope: true
            )
        }
        .mediaCueSheets(model: model, state: mediaMenuState)
        .alert(
            "Edit a Repeated Section?",
            isPresented: Binding(
                get: { pendingEdit != nil }, set: { if !$0 { pendingEdit = nil } }
            ),
            presenting: pendingEdit
        ) { edit in
            Button("Apply") {
                edit.apply()
                pendingEdit = nil
            }
            Button("Cancel", role: .cancel) { pendingEdit = nil }
        } message: { edit in
            Text(
                "This will affect every "
                    + edit.sectionNames.map { "“\($0)”" }.joined(separator: " and ")
                    + " instance in the arrangement."
            )
        }
        .alert(
            "Rename Slide",
            isPresented: Binding(
                get: { renamingSlide != nil }, set: { if !$0 { renamingSlide = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let slide = renamingSlide {
                    model.renameSlide(presentation.id, slideID: slide.id, to: renameText)
                }
                renamingSlide = nil
            }
            Button("Cancel", role: .cancel) { renamingSlide = nil }
        } message: {
            Text("Leave empty for no name — slides don't need one.")
        }
    }

    private func clearSelection() {
        selectedOccurrences.removeAll()
        selectionAnchor = nil
    }

    /// The page's box, in this grid's own coordinates: its slides under it.
    private func selectUnder(_ local: CGRect) {
        let hit = Set(tileFrames.filter { $0.value.intersects(local) }.map(\.key))
        if hit != selectedOccurrences { selectedOccurrences = hit }
        // Paste goes to the last item the box reaches.
        if !hit.isEmpty { NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID) }
    }

    /// On the plan page the box is the page's (so it reaches every item);
    /// in a single presentation, this grid's own.
    private var marqueeGesture: some Gesture {
        DragGesture(
            minimumDistance: 4,
            coordinateSpace: pageMarquee == nil ? .named("slideGrid") : .named(ServiceContinuousView.contentSpace))
            .onChanged { value in
                guard !runOnly else { return }
                if let pageMarquee {
                    pageMarquee.update(start: value.startLocation, location: value.location)
                    return
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marqueeRect = rect
                NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID)
                selectedOccurrences = Set(
                    tileFrames.filter { $0.value.intersects(rect) }.map(\.key))
            }
            .onEnded { _ in
                marqueeRect = nil
                pageMarquee?.end()
            }
    }

    private func handleTap(index: Int, slide: Slide) {
        let modifiers = NSEvent.modifierFlags

        NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID, occurrence: index)
        pageMarquee?.own(contextID)
        if !runOnly, modifiers.contains(.command) {
            if selectedOccurrences.contains(index) {
                selectedOccurrences.remove(index)
            } else {
                selectedOccurrences.insert(index)
            }
            selectionAnchor = index
        } else if !runOnly, modifiers.contains(.shift) {
            let anchor = selectionAnchor ?? index
            selectedOccurrences.formUnion(min(anchor, index)...max(anchor, index))
        } else {
            clearSelection()

            let isLiveTile = controls?.liveContextID == contextID && controls?.liveOccurrence == index
            if isLiveTile, let controls, controls.slideAnimationStep.map({ $0.consumed < $0.total }) == true {
                controls.advance(steps: 1) {}
            } else {
                controls?.fire(
                    slide: slide, in: presentation, arrangementId: arrangementId,
                    contextID: contextID, occurrence: index
                )
                LiveAssist.shared.operatorTookOver(firing: index, contextID: contextID)
            }
        }
    }

    private func menuTargetIDs(clicked index: Int, slide: Slide) -> [String] {
        guard selectedOccurrences.contains(index) else { return [slide.id] }
        return SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
    }

    @ViewBuilder
    fileprivate func tileMenu(index: Int, slide: Slide) -> some View {
        if !runOnly {
            let targetIDs = menuTargetIDs(clicked: index, slide: slide)
            if targetIDs.count > 1 {
                bulkMenu(slideIDs: targetIDs)
            } else {
                singleMenu(slide: slide)
            }
        }
    }

    @ViewBuilder
    private func bulkMenu(slideIDs: [String]) -> some View {
        Text("\(slideIDs.count) Slides")
        Button("Screens…") { screensTarget = SlideScreensTarget(slideIDs: slideIDs) }
        themeMenu(slideIDs)
        livestreamMenu(slideIDs)
        stageToggle(slideIDs)
        listenButton()
        Menu("Add Action") {
            AddActionMenuItems(
                model: model,
                timers: actionRouter?.timerChoices ?? []
            ) { action in

                actionPlacement = ActionPlacement(slideIDs: slideIDs, draft: action)
            }
        }
        prismMenu(slideIDs)
        let kinds = SlideBulkEdit.actionKinds(on: slideIDs, in: presentation.slides)
        if !kinds.isEmpty {
            Menu("Remove Action") {
                ForEach(kinds, id: \.rawValue) { kind in
                    Button(kind.displayName, role: .destructive) {
                        model.updateSlides(presentationID: presentation.id, undoLabel: "Remove Action") {
                            SlideBulkEdit.removeActions(
                                ofKind: kind, from: slideIDs, in: &$0)
                        }
                    }
                }
                Divider()
                Button("All Actions", role: .destructive) {
                    model.updateSlides(presentationID: presentation.id, undoLabel: "Remove Actions") {
                        SlideBulkEdit.removeActions(
                            ofKind: nil, from: slideIDs, in: &$0)
                    }
                }
            }
        }
        Button(anyHasAutoAdvance(slideIDs) ? "Auto Advance… ✓" : "Auto Advance…") {
            autoAdvanceTarget = AutoAdvanceTarget(
                slideIDs: slideIDs, name: "\(slideIDs.count) Slides")
        }
        Button(presentation.autoAdvance == nil ? "Slide Show…" : "Slide Show… ✓") {
            slideShowPresented = true
        }
        Divider()
        Button("Duplicate \(slideIDs.count) Slides") {
            confirmingRepeatedSectionEdit(sections: sectionIDs(of: slideIDs)) {

                var copied = presentation.slides
                SlideBulkEdit.duplicateSlides(slideIDs, in: &copied)
                if let insertion = ListInsertion(before: presentation.slides, after: copied, id: { $0.id }) {
                    model.updatePresentation(presentation.id, value: { insertion.restore(into: &$0.slides) }, op: { document in
                        try document.updateSlideList { insertion.restore(into: &$0) }
                    })
                }
                clearSelection()
            }
        }
        Button("Copy \(slideIDs.count) Slides") { copySlides(slideIDs) }
        // Every slide may go: an empty presentation shows its drop area.
        Button("Delete \(slideIDs.count) Slides", role: .destructive) {
            deleteSlides(slideIDs)
        }
    }

    private func copySlides(_ slideIDs: [String]) {
        SlidePasteboard.copy(presentation.slides.filter { slideIDs.contains($0.id) })
    }

    @discardableResult
    private func copySelectedSlides() -> Bool {
        let slideIDs = SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
        if !runOnly, !slideIDs.isEmpty {
            // A box across several items: each grid adds its slides to the
            // same copy instead of replacing the one before.
            SlidePasteboard.appendsCopy = pageMarquee != nil && SlidePasteboard.copyGeneration == clipboardRequests.round
            SlidePasteboard.copyGeneration = clipboardRequests.round
            copySlides(slideIDs)
            return true
        } else {
            return false
        }
    }

    private func pasteFromKeyboard() {
        // One paste, into the item last clicked or boxed, not one per item
        // that has slides selected.
        let route = NewSlideRouter.shared.route
        if pageMarquee != nil, let routed = route.contextID, routed != contextID { return }
        // On the page, after the live slide only when a slide here was
        // clicked: an item the page pointed at by itself would get the
        // slides in the middle of what fires next.
        let followsLive = pageMarquee == nil || route.clickedSlide(in: contextID)
        let liveIndex = followsLive && controls?.liveContextID == contextID ? controls?.liveOccurrence : nil
        let anchorIndex = selectedOccurrences.max() ?? liveIndex
        if !runOnly, let anchorIndex, slides.indices.contains(anchorIndex) {
            pasteSlides(after: slides[anchorIndex])
        } else if !runOnly, hostsPaste {
            pasteSlides(after: presentation.slides.last)
        }
    }

    private func selectAllFromKeyboard() {
        let contexts = newSlideContexts.isEmpty ? [contextID] : newSlideContexts
        if !runOnly, NewSlideRouter.shared.route.answers(contextID, contexts: contexts, isHostTarget: hostsPaste) {
            selectedOccurrences = Set(slides.indices)
            selectionAnchor = nil
        } else if !runOnly {
            clearSelection()
        }
    }

    private func pasteSlides(after anchor: Slide?) {
        let pasted = SlidePasteboard.pasteAll()
        if !pasted.isEmpty {
            confirmingRepeatedSectionEdit(sections: [anchor?.sectionId]) {
                model.insertSlides(presentation.id, slides: pasted, afterSlideID: anchor?.id)
            }
        }
    }

    private func newSlideFromMenu() {
        let route = NewSlideRouter.shared.route
        let contexts = newSlideContexts.isEmpty ? [contextID] : newSlideContexts
        if !runOnly, route.answers(contextID, contexts: contexts, isHostTarget: hostsPaste) {
            let anchor = route.anchor(in: contextID, selected: selectedOccurrences, count: slides.count)
            newSlideTarget = NewSlideTarget(after: anchor.map { slides[$0] } ?? presentation.slides.last)
        }
    }

    private func insertNewSlide(_ choice: NewSlideChoice, after anchor: Slide?) {
        let slide = choice.slide(sectionId: anchor?.sectionId, deckThemeId: presentation.themeId)
        confirmingRepeatedSectionEdit(sections: [anchor?.sectionId]) {
            model.insertSlide(presentation.id, slide: slide, afterSlideID: anchor?.id)
        }
    }

    private func deleteSelectedSlides() {
        guard !runOnly, !selectedOccurrences.isEmpty else { return }
        let slideIDs = SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
        guard !slideIDs.isEmpty else { return }
        deleteSlides(slideIDs)
    }

    private func deleteSlides(_ slideIDs: [String]) {
        confirmingRepeatedSectionEdit(sections: sectionIDs(of: slideIDs)) {

            model.updatePresentation(presentation.id, value: { SlideBulkEdit.deleteSlides(slideIDs, in: &$0.slides) }, op: { document in
                try document.updateSlideList { SlideBulkEdit.deleteSlides(slideIDs, in: &$0) }
            })
            clearSelection()
        }
    }

    private func anyHasAutoAdvance(_ slideIDs: [String]) -> Bool {
        presentation.slides.contains { slideIDs.contains($0.id) && $0.autoAdvance != nil }
    }

    private func cueMediaIDs(of slide: Slide) -> [String] {
        var ids: [String] = []
        if let id = slide.background?.mediaId, !id.isEmpty, !id.contains("::") {
            ids.append(id)
        }
        for action in slide.actions ?? [] where action.kind == .fireMedia {
            guard let id = action.mediaId, !id.isEmpty, !id.contains("::"),
                  !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    private func sectionIDs(of slideIDs: [String]) -> [String?] {
        presentation.slides.filter { slideIDs.contains($0.id) }.map(\.sectionId)
    }

    private func addAction(_ action: SlideAction, to slideIDs: [String]) {

        let ids = Dictionary(Set(slideIDs).map { ($0, UUID().uuidString) }, uniquingKeysWith: { first, _ in first })
        var preview = presentation
        let pairs = SlideBulkEdit.addAction(action, to: slideIDs, in: &preview, actionIDs: ids)
        model.updateSlides(presentationID: presentation.id, undoLabel: "Add Action") {
            SlideBulkEdit.addAction(action, to: slideIDs, in: &$0, actionIDs: ids)
        }
        if action.kind == .fireMedia, action.mediaId == nil, !pairs.isEmpty {
            mediaActionTarget = MediaActionTarget(pairs: pairs)
        }
        if action.kind == .fireAudio, action.audioItemId == nil, !pairs.isEmpty {
            mediaActionTarget = MediaActionTarget(pairs: pairs, kind: .audio)
        }
    }

    private func missingMedia(of slide: Slide) -> [String] {
        MediaReferences.ids(in: slide).sorted().filter(model.isMediaMissing(mediaID:))
    }

    @ViewBuilder
    private func singleMenu(slide: Slide) -> some View {

        Button("Screens…") { screensTarget = SlideScreensTarget(slideIDs: [slide.id]) }
        themeMenu([slide.id])
        livestreamMenu([slide.id])
        stageToggle([slide.id])
        listenButton()
        Divider()
        Button("Edit…") {
            model.openInEditor(
                entryID: presentation.id, slideID: slide.id
            )
            HotDefaults.setAppMode(.edit)
        }
        Button("Quick Edit…") { quickEditSlide = slide }
        if let event = slide.sourceEvent {
            Button("Don\u{2019}t Show This Event") { WebsiteEventSync.shared.hide(event) }
                .help("Leaves \(event.title) out of the slideshow, and its later dates too. Settings › Integrations › Website brings it back.")
        }
        // A song's chords for the stage display, on this slide.
        if presentation.presentationKind == .song || slide.objects.contains(where: { !($0.chords ?? []).isEmpty }) {
            Button("Edit Chords…") { chordsSlide = IdentifiedID(id: slide.id) }
            Button("Chords Window…") {
                openWindow(id: "chords", value: ChordsWindowTarget(
                    presentationID: presentation.id, sectionID: slide.sectionId ?? ""))
            }
        }
        // The song's look: its theme in the editor, or made the worship theme.
        if presentation.presentationKind == .song {
            if let themeID = model.followedWorshipTheme(of: slide, in: presentation),
               let name = model.libraryEntry(themeID)?.name {
                Button("Edit Theme \u{201C}\(name)\u{201D}…") {
                    model.openInEditor(entryID: themeID)
                    HotDefaults.setAppMode(.edit)
                }
            }
            Button("Make This the Worship Theme…") { worshipThemeSlide = slide }
        }
        Button("Rename Slide…") {
            renameText = slide.name
            renamingSlide = slide
        }
        let files = model.mediaFiles(on: slide)
        if files.count == 1, let item = files.first {
            Button("Show in Finder") { model.showMediaInFinder(item) }
                .disabled(model.isMediaFileMissing(item))
        } else if files.count > 1 {
            Menu("Show in Finder") {
                ForEach(files, id: \.id) { item in
                    Button(item.name) { model.showMediaInFinder(item) }
                        .disabled(model.isMediaFileMissing(item))
                }
            }
        }

        prismMenu([slide.id])

        if ChurchBrowser.shows(slide) {
            Button("Browser Site\u{2026}") {
                guard let site = BrowserSitePrompt.ask(current: ChurchBrowser.site(on: slide) ?? "") else { return }
                model.updateSlides(presentationID: presentation.id, undoLabel: "Browser Site") { deck in
                    for index in deck.slides.indices where deck.slides[index].id == slide.id {
                        deck.slides[index] = ChurchBrowser.setting(site: site, on: deck.slides[index])
                    }
                }
            }
        }

        ForEach(cueMediaIDs(of: slide), id: \.self) { mediaID in
            Menu(model.media(mediaID)?.name ?? "Media") {

                MediaCueMenuItems(
                    model: model, actionRouter: actionRouter,
                    mediaID: mediaID, state: mediaMenuState,
                    includesCueGrammar: false
                )
            }
        }

        Menu("Add Action") {
            AddActionMenuItems(
                model: model,
                timers: actionRouter?.timerChoices ?? []
            ) { action in
                actionPlacement = ActionPlacement(slideIDs: [slide.id], draft: action)
            }
        }

        let slideActions = slide.actions ?? []
        if !slideActions.isEmpty {

            let timers = actionRouter?.timerChoices ?? []
            Menu("Edit Action") {
                ForEach(slideActions) { action in
                    Button(slideActionLabel(
                        action, model: model, timers: timers,
                        confidenceScreens: actionRouter?.confidenceScreenChoices ?? [])) {
                        actionEditorSlide = slide
                    }
                }
            }
            Menu("Remove Action") {
                ForEach(slideActions) { action in
                    Button(slideActionLabel(
                        action, model: model, timers: timers,
                        confidenceScreens: actionRouter?.confidenceScreenChoices ?? []), role: .destructive) {
                        removeSlideAction(action.id, from: slide)
                    }
                }
            }
        }

        Button(slide.autoAdvance == nil
            ? "Auto Advance…" : "Auto Advance… ✓"
        ) {
            autoAdvanceTarget = AutoAdvanceTarget(slideIDs: [slide.id], name: slide.name)
        }
        Button(presentation.autoAdvance == nil ? "Slide Show…" : "Slide Show… ✓") {
            slideShowPresented = true
        }
        Divider()
        Button("New Slide After…") { newSlideTarget = NewSlideTarget(after: slide) }
        Button("Duplicate Slide") {
            confirmingRepeatedSectionEdit(sections: [slide.sectionId]) {
                model.insertSlide(
                    presentation.id, slide: slide.freshIDCopy(),
                    afterSlideID: slide.id
                )
            }
        }
        Button("Copy Slide") { SlidePasteboard.copy(slide) }

        let _ = SlidePasteboardChanges.shared.count
        Button("Paste Slide After") { pasteSlides(after: slide) }
            .disabled(!SlidePasteboard.hasSlide)

        Button("Delete Slide", role: .destructive) {
            deleteSlides([slide.id])
        }
    }

    /// Theme › every theme, each with its designs (Title, Bible, Sermon
    /// Points…): a slide's theme and its design are chosen in one place.
    /// The slides' theme comes first; lower-third themes aren't listed,
    /// since a slide on the room's screens can't use one.
    private func themeMenu(_ slideIDs: [String]) -> some View {
        let slides = presentation.slides.filter { slideIDs.contains($0.id) }
        let currentThemes = Set(slides.map { presentation.themeId(for: $0) })
        var current: Set<String> = []
        for slide in slides {
            let designs = Self.fullScreenDesigns(model.theme(for: slide, in: presentation))
            // A slide asking for "Scripture" is on the theme's "Bible".
            let name = slide.themeSlideName ?? ""
            current.insert(name.isEmpty ? "" : ThemeCategories.match(name, in: designs)?.name ?? name)
        }
        let worship = model.slideBuilding.lyricsImportThemeId
        let themes = menuThemes.filter { entry in
            model.resident.themes.value(entry.id)
                .map { ThemeGallery.group(of: $0, worshipThemeId: worship) != .lowerThirds } ?? true
        }
        let ordered = themes.filter { currentThemes.contains($0.id) } + themes.filter { !currentThemes.contains($0.id) }
        // Each theme's designs, read from the themes already in memory
        // before the menu is built, not while it opens.
        var designsByTheme: [String: [String]] = [:]
        for entry in ordered {
            designsByTheme[entry.id] = Self.fullScreenDesigns(model.resident.themes.value(entry.id)).map(\.name)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
        return Menu("Theme") {
            ForEach(ordered, id: \.id) { entry in
                let isCurrent = currentThemes == [entry.id]
                let designs = designsByTheme[entry.id] ?? []
                Menu((isCurrent ? "\u{2713} " : "") + entry.name) {
                    Button((isCurrent && current == [""] ? "\u{2713} " : "") + StreamWording.themeDefault) {
                        chooseTheme(entry.id, design: nil, for: slideIDs, isCurrent: isCurrent)
                    }
                    if !designs.isEmpty { Divider() }
                    ForEach(designs, id: \.self) { design in
                        Button((isCurrent && current == [design] ? "\u{2713} " : "") + design) {
                            chooseTheme(entry.id, design: design, for: slideIDs, isCurrent: isCurrent)
                        }
                    }
                }
            }
            Divider()
            Button("Choose Theme\u{2026}") {
                applyThemeTarget = ApplyThemeTarget(presentationID: presentation.id, slideIDs: slideIDs)
            }
        }
        .disabled(themes.isEmpty)
    }

    private static func fullScreenDesigns(_ theme: Theme?) -> [Slide] {
        (theme?.slides ?? []).filter { !ThemeGallery.isLowerThirdDesign($0) }
    }

    /// The slides on `themeID`'s `design` (nil: the theme's default). On
    /// their own theme already, only the design changes.
    private func chooseTheme(_ themeID: String, design: String?, for slideIDs: [String], isCurrent: Bool) {
        if isCurrent {
            setLayout(design, of: slideIDs)
        } else {
            model.changeTheme(of: slideIDs, in: presentation.id, to: themeID, design: .some(design))
        }
    }

    private func setLayout(_ category: String?, of slideIDs: [String]) {
        let ids = Set(slideIDs)
        model.updateSlides(presentationID: presentation.id, undoLabel: "Layout") { deck in
            for index in deck.slides.indices where ids.contains(deck.slides[index].id) {
                deck.slides[index].themeSlideName = category
            }
        }
    }

    /// Livestream › the same choices as the Screens sheet and the theme's
    /// routing table. A choice here wins over the Show Setup switch.
    private func livestreamMenu(_ slideIDs: [String]) -> some View {
        let chosen = presentation.slides.filter { slideIDs.contains($0.id) }
        let current = Set(chosen.map { slide -> String in
            guard let own = slide.streamDesign else { return "default" }
            if let image = own.lowerThirdImageID { return "image|\(image)" }
            switch own.mode {
            case .clear: return "clear"
            case .audience: return "audience"
            case .design: return own.isThemeLowerThird ? "lowerThird" : "design"
            }
        })
        let image = current.count == 1 ? chosen.first?.streamDesign?.lowerThirdImageID : nil
        let withImage = chosen.filter { $0.streamDesign?.lowerThirdImageID != nil }.map(\.id)
        let choices: [(key: String, title: String, design: StreamDesign?)] = [
            ("default", StreamWording.themeDefault, nil),
            ("lowerThird", StreamWording.lowerThird, .slideLowerThird),
            ("audience", StreamWording.fullScreen, .slideFullScreen),
            ("clear", StreamWording.nothing, .slideNothing),
        ]
        return Menu("Livestream") {
            ForEach(choices, id: \.key) { choice in
                Button((current == [choice.key] ? "✓ " : "") + choice.title) {
                    setStreamDesign(choice.design, of: slideIDs)
                }
                if choice.key == "default" { Divider() }
            }
            // One named lower third, from any theme that has them.
            // Ticked only when every chosen slide has the same one.
            let designs = Set(chosen.map { "\($0.streamDesign?.themeId ?? "")|\($0.streamDesign?.slideId ?? "")" })
            let own = current == ["design"] && designs.count == 1 ? chosen.first?.streamDesign : nil
            let themes = LowerThirdChoices.themes(model)
            if !themes.isEmpty {
                let listed = themes.contains { theme in
                    theme.id == own?.themeId && theme.thirds.contains { $0.id == own?.slideId }
                }
                Menu((listed ? "✓ " : "") + StreamWording.chooseLowerThird) {
                    ForEach(themes) { entry in
                        Menu(entry.name) {
                            ForEach(entry.thirds, id: \.id) { design in
                                let on = own?.themeId == entry.id && own?.slideId == design.id
                                Button((on ? "✓ " : "") + design.name) {
                                    setStreamDesign(
                                        StreamDesign(category: "", mode: .design, themeId: entry.id, slideId: design.id),
                                        of: slideIDs)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            if let image {
                Button("✓ " + (model.media(image)?.name ?? "Lower-Third Image")) {}
                    .disabled(true)
            }
            Button(StreamWording.lowerThirdImage) {
                LowerThirdImagePicker.choose(model) { setStreamDesign(.lowerThirdImage($0), of: slideIDs) }
            }
            if !withImage.isEmpty {
                // Back to Theme Default, and only on the slides that had one.
                Button(StreamWording.removeLowerThirdImage) { setStreamDesign(nil, of: withImage) }
            }
        }
    }

    private func setStreamDesign(_ design: StreamDesign?, of slideIDs: [String]) {
        let ids = Set(slideIDs)
        model.updateSlides(presentationID: presentation.id, undoLabel: "Livestream") { deck in
            for index in deck.slides.indices where ids.contains(deck.slides[index].id) {
                deck.slides[index].streamDesign = design
            }
        }
        actionRouter?.noteStreamDesign(design, forSlides: ids)
    }

    /// Show on Stage Display: while these slides are up, the stage shows the
    /// audience screen too. The slides' own stage choice, so the Screens
    /// sheet and the editor's Stage picker show it as Audience Screen.
    private func stageToggle(_ slideIDs: [String]) -> some View {
        let slides = presentation.slides.filter { slideIDs.contains($0.id) }
        let on = !slides.isEmpty && slides.allSatisfy { $0.stageLayoutId == StageLayouts.audienceID }
        return Button((on ? "✓ " : "") + StageWording.showOnStage) {
            let ids = Set(slideIDs)
            let layoutID = on ? nil : StageLayouts.audienceID
            model.updateSlides(presentationID: presentation.id, undoLabel: "Stage Display") { deck in
                for index in deck.slides.indices where ids.contains(deck.slides[index].id) {
                    deck.slides[index].stageLayoutId = layoutID
                }
            }
            actionRouter?.noteStageLayout(layoutID, forSlides: ids)
        }
    }

    /// Listens to the pastor and puts each passage they mention on screen
    /// as it's said, without opening the Sermon tab.
    @ViewBuilder
    private func listenButton() -> some View {
        let assist = LiveAssist.shared
        if assist.listening && assist.mode == .sermon {
            Button("Stop Listening") { assist.stop() }
        } else {
            Button("Start Listening for Scripture") {
                assist.showsAutomatically = true
                Task { await assist.startSermon() }
            }
        }
    }

    /// Change Theme › one entry per theme (each sermon series is its own).
    private var menuThemes: [LibraryIndex.Entry] {
        model.entries(of: .theme).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func applyThemeScope(_ slideIDs: [String]) -> String {
        if Set(slideIDs).isSuperset(of: presentation.slides.map(\.id)) {
            "Applies to every slide in \u{201C}\(presentation.name)\u{201D}."
        } else if slideIDs.count == 1 {
            "Applies to this slide."
        } else {
            "Applies to the \(slideIDs.count) selected slides."
        }
    }

    private func gridTile(index: Int, slide: Slide, aspect: CGFloat) -> some View {
        tile(index: index, slide: slide, aspect: aspect)

            .newSlideEdgeMenu(enabled: !runOnly, choices: AddSlideChoices(
                fromTheme: { newSlideTarget = NewSlideTarget(after: slide, startsWithThemes: true) },
                fromMedia: {
                    mediaSlideTarget = MediaSlideTarget(
                        presentationID: presentation.id, afterSlideID: slide.id, beforeIndex: index + 1)
                },
                blank: { insertNewSlide(.blank, after: slide) },
                browser: { insertNewSlide(.browser(site: $0), after: slide) }
            ))

            .id(Self.tileAnchor(contextID: contextID, index: index))
    }

    private func tile(index: Int, slide: Slide, aspect: CGFloat) -> some View {
        SlideTile(
            model: model, render: render,
            slide: slide, index: index, aspect: aspect,

            presentation: presentation,
            theme: slide.themeId != nil || slide.unthemed == true ? model.theme(for: slide, in: presentation) : theme,
            arrangementId: arrangementId,

            controls: controls,
            isSelected: selectedOccurrences.contains(index),
            roundedCorners: roundedCorners,
            hideScopedBackgrounds: hideScopedBackgrounds,
            legibleText: legibleText,
            contextID: contextID
        ) {
            handleTap(index: index, slide: slide)
        }

        .modifier(TileFrameReport(box: cell == nil ? tileFrameBox : nil, index: index))
        .draggablePayload(runOnly ? nil : SlideBulkEdit.slideDragPayload(
            presentationID: presentation.id, slideID: slide.id))
        // The drag source stays on the tile. It is also what lets a click
        // on a slide fire while another app is in front: with a drag source
        // under the pointer SwiftUI takes the first click in a window that
        // isn't active, and without one that click only brings the window
        // forward. The drop target and the right-click menu are the grid's
        // (SlideGridDropDelegate, SlideGridMenuPress).
    }

    /// A drop on a tile: the grid's drop target found the tile and the
    /// place on it.
    private func dropOnTile(
        _ hit: SlideDropPlacement.TileHit, at place: SlideDropPlacement.Target, _ payload: DraggedPayload
    ) -> Bool {
        dropMarks.clear()
        guard !runOnly, slides.indices.contains(hit.index) else { return false }
        let index = hit.index
        let slide = slides[index]
        if let text = payload.text, GutterDropDelegate.forcesInsert(payload: text) {
            // A slide dragged here goes after the tile from its far half,
            // before it from its near half.
            if place == .after(index) { return dropSlide(text, after: slide) }
            return handleTileText(text, index: index, slide: slide, insertZone: hit.x < SlideDropPlacement.minimumEdge)
        }
        if place == .after(index) {
            if !payload.files.isEmpty {
                insertMediaFiles(payload.files, at: .after(index))
                return true
            }
            return payload.text.map { dropText($0, at: .after(index)) } ?? false
        }
        let beside = place == .before(index)
        if !payload.files.isEmpty {
            handleTileFiles(payload.files, index: index, slide: slide, insertZone: beside)
            return true
        }
        return payload.text.map { handleTileText($0, index: index, slide: slide, insertZone: beside) } ?? false
    }

    /// A drop in the space around the tiles.
    private func dropInGap(_ place: SlideDropPlacement.Target, _ payload: DraggedPayload) -> Bool {
        dropMarks.clear()
        guard !runOnly else { return false }
        if !payload.files.isEmpty {
            insertMediaFiles(payload.files, at: place)
            return true
        }
        return payload.text.map { dropText($0, at: place) } ?? false
    }

    private func handleTileText(
        _ payload: String, index: Int, slide: Slide, insertZone: Bool
    ) -> Bool {

        dropMarks.clear()
        defer {
            Task { @MainActor in dropMarks.clear() }
        }
        guard !runOnly else { return false }
        if payload.hasPrefix("mxuslide::") {

            return dropSlide(payload, before: slide)
        }

        let resolved = model.indexEntry(payload)
        DiagnosticsStore.shared.note(
            "grid.drop.text",
            detail: "insert=\(insertZone) kind=\(resolved?.kind.rawValue ?? "unresolved") payload=\(payload.prefix(40))")
        // Beside a slide, a picture or video becomes a new slide; anything
        // else near the edge does what it does on the slide.
        if insertZone, model.media(payload) != nil {
            return insertMediaSlides(mediaIDs: [payload], at: .before(index))
        }
        if let entry = resolved, entry.kind == .actionCombo {
            appendSlideAction(
                SlideAction(id: UUID().uuidString, kind: .fireCombo, comboId: entry.id),
                to: slide)
            return true
        }

        if payload.hasPrefix("pltrk::") {
            return false
        }
        return model.setSlideBackground(
            presentationID: presentation.id, slideID: slide.id, mediaID: payload)
    }

    /// Right-click › Prism: the scene these slides cue when they go up.
    /// The one they all cue is ticked.
    private func prismMenu(_ slideIDs: [String]) -> some View {
        let cues = presentation.slides
            .filter { slideIDs.contains($0.id) }
            .map { PrismScenes.cue(on: $0)?.prismCueId }
        let current = Set(cues).count == 1 ? cues.first ?? nil : nil
        return Menu("Prism") {
            PrismSceneMenuItems(
                model: model, current: current,
                offersNone: cues.contains { $0 != nil }
            ) { scene in
                setPrismScene(scene, on: slideIDs)
            }
        }
    }

    private func setPrismScene(_ scene: PrismScene?, on slideIDs: [String]) {
        let ids = Set(slideIDs)
        model.updateSlides(presentationID: presentation.id, undoLabel: "Prism Scene") { deck in
            for index in deck.slides.indices where ids.contains(deck.slides[index].id) {
                deck.slides[index] = PrismScenes.setting(scene, on: deck.slides[index])
            }
        }
    }

    private func appendSlideAction(_ action: SlideAction, to slide: Slide) {
        let appended = model.updateSlide(
            presentationID: presentation.id, slideID: slide.id, undoLabel: "Add Action"
        ) { target in
            target.actions = (target.actions ?? []) + [action]
        }
        if appended {
            let number = (presentation.slides.firstIndex { $0.id == slide.id } ?? 0) + 1
            DiagnosticsStore.shared.note(
                "grid.drop.appended", detail: "\(action.kind.rawValue) -> slide \(number)")
        } else {
            DiagnosticsStore.shared.note(
                "grid.drop.appendMiss", detail: "slide \(slide.id) not in \(presentation.id)")
        }
    }

    private func autoAdvanceBinding(_ slideIDs: [String]) -> Binding<AutoAdvance?> {
        Binding(
            get: {
                model.presentation(presentation.id)?.slides
                    .first { slideIDs.contains($0.id) }?.autoAdvance
            },
            set: { advance in
                model.updateSlides(presentationID: presentation.id, undoLabel: "Auto Advance") { presentation in
                    SlideBulkEdit.setAutoAdvance(advance, on: slideIDs, in: &presentation)
                }
            }
        )
    }

    private func removeSlideAction(_ actionID: String, from slide: Slide) {
        model.updateSlide(presentationID: presentation.id, slideID: slide.id, undoLabel: "Remove Action") { target in
            var actions = target.actions ?? []
            actions.removeAll { $0.id == actionID }

            target.actions = actions.isEmpty ? nil : actions
        }
    }

    private func slideActionsBinding(_ slideID: String) -> Binding<[SlideAction]> {
        Binding(
            get: {
                model.presentation(presentation.id)?.slides
                    .first { $0.id == slideID }?.actions ?? []
            },
            set: { actions in
                model.updateSlide(presentationID: presentation.id, slideID: slideID, undoLabel: "Edit Actions") {
                    $0.actions = actions.isEmpty ? nil : actions
                }
            }
        )
    }

    private func handleTileFiles(_ urls: [URL], index: Int, slide: Slide, insertZone: Bool) {
        dropMarks.clear()
        guard !runOnly, !urls.isEmpty else { return }
        if insertZone {
            insertMediaFiles(urls, at: .before(index))
            return
        }
        let slideID = slide.id
        Task { @MainActor in
            guard let first = await model.importFiles(urls).first else { return }
            _ = model.setSlideBackground(
                presentationID: presentation.id, slideID: slideID, mediaID: first)
        }
    }

    /// Files from the Finder dropped between slides: imported into the
    /// media library, then every picture and video becomes a slide there, so
    /// a folder of announcements lands in one go.
    private func insertMediaFiles(_ urls: [URL], at place: SlideDropPlacement.Target) {
        guard !runOnly, !urls.isEmpty else { return }
        // Named by the slide beside it now: the import can take a while, and
        // the grid may change under it.
        let anchor = SlideDropPlacement.anchor(for: place, in: slides.map(\.id))
        Task { @MainActor in
            await model.importForSlides(urls) { imported in
                guard let anchor, !imported.isEmpty else { return }
                _ = insertMediaSlides(mediaIDs: imported, anchor: anchor)
            }
        }
    }

    /// A library id or a slide dropped beside a tile or in the space around
    /// them: a picture or video becomes a new slide there, a slide moves or
    /// is copied there.
    private func dropText(_ payload: String, at place: SlideDropPlacement.Target) -> Bool {
        guard !runOnly else { return false }
        if SlideBulkEdit.draggedSlide(in: payload) != nil {
            switch place {
            case .before(let index) where slides.indices.contains(index):
                return dropSlide(payload, before: slides[index])
            case .after(let index) where slides.indices.contains(index):
                return dropSlide(payload, after: slides[index])
            default:
                return false
            }
        }
        guard !payload.contains("::"), model.media(payload) != nil else { return false }
        return insertMediaSlides(mediaIDs: [payload], at: place)
    }

    /// What the space around the tiles takes: pictures and videos from the
    /// media bin or the Finder, and slides.
    private func gapAccepts(_ payload: DraggedPayload) -> Bool {
        if !payload.files.isEmpty { return payload.files.contains(where: MediaSlideBuilder.makesSlides) }
        guard let text = payload.text else { return false }
        if SlideBulkEdit.draggedSlide(in: text) != nil { return true }
        return !text.contains("::") && model.media(text) != nil
    }

    /// New slides from pictures or videos at a place in the grid, then the
    /// livestream question for them.
    private func insertMediaSlides(mediaIDs: [String], at place: SlideDropPlacement.Target) -> Bool {
        guard let anchor = SlideDropPlacement.anchor(for: place, in: slides.map(\.id)) else { return false }
        return insertMediaSlides(mediaIDs: mediaIDs, anchor: anchor)
    }

    private func insertMediaSlides(mediaIDs: [String], anchor: SlideDropPlacement.Anchor) -> Bool {
        guard !runOnly else { return false }
        let made = MediaSlides.make(mediaIDs, model: model, existing: presentation.slides)
        for (slideID, lowerThird) in made.existingLowerThirds {
            setStreamDesign(.lowerThirdImage(lowerThird), of: [slideID])
        }
        let added = made.slides
        guard !added.isEmpty else { return !made.existingLowerThirds.isEmpty }
        // The new slides join the section beside them; when it repeats (a
        // chorus sung three times) they'd show in every repeat, so ask first
        // as a slide drag does.
        confirmingRepeatedSectionEdit(sections: [SlideDropPlacement.sectionId(at: anchor, in: presentation)]) {
            model.insertSlides(presentation.id, slides: added, at: anchor)
            askLivestream(for: added)
        }
        return true
    }

    /// A presentation with no slides in the grid: one tile-sized space to
    /// drop its first slide into, with the "+" choices, as the plan page
    /// shows for one.
    private func emptyDeckArea(aspect: CGFloat, cell: CGSize?) -> some View {
        VStack(spacing: SlideGridMetrics.labelGap) {
            EmptySlidesDropArea(
                aspect: aspect,
                locked: runOnly,
                choices: AddSlideChoices(
                    fromTheme: { newSlideTarget = NewSlideTarget(after: nil, startsWithThemes: true) },
                    fromMedia: {
                        mediaSlideTarget = MediaSlideTarget(presentationID: presentation.id, afterSlideID: nil)
                    },
                    blank: { insertNewSlide(.blank, after: nil) },
                    browser: { insertNewSlide(.browser(site: $0), after: nil) }
                ),
                dropText: { payload in
                    if let dragged = SlideBulkEdit.draggedSlide(in: payload) {
                        return !runOnly && dragged.presentationID != presentation.id
                            && model.presentationExists(dragged.presentationID)
                            && model.copySlide(dragged.slideID, from: dragged.presentationID, to: presentation.id)
                    }
                    return dropText(payload, at: .before(0))
                },
                dropFiles: { urls in insertMediaFiles(urls, at: .before(0)) },
                breadcrumb: "present.emptyGridDrop",
                roundedCorners: roundedCorners
            )
            Color.clear.frame(height: SlideGridMetrics.labelHeight)
        }
        .frame(width: cell?.width ?? 240)
    }

    private func askLivestream(for added: [Slide]) {
        let presentationID = presentation.id
        let asked = LivestreamPromptRequest.make(model, presentationID: presentationID, added: added) { design, ids in
            setStreamDesign(design, of: ids)
        }
        guard let asked else { return }
        livestreamPrompt = livestreamPrompt.map { $0.adding(asked) } ?? asked
    }

    private func dropSlide(_ payload: String, before target: Slide) -> Bool {
        if let dragged = SlideBulkEdit.draggedSlide(in: payload), dragged.slideID != target.id {
            if dragged.presentationID == presentation.id,
               let source = presentation.slides.first(where: { $0.id == dragged.slideID }) {

                confirmingRepeatedSectionEdit(sections: [source.sectionId, target.sectionId]) {
                    model.moveSlide(presentation.id, slideID: source.id, beforeSlideID: target.id)
                }
                return true
            } else if dragged.presentationID != presentation.id,
                      model.presentationExists(dragged.presentationID) {

                confirmingRepeatedSectionEdit(sections: [target.sectionId]) {
                    model.copySlide(
                        dragged.slideID, from: dragged.presentationID,
                        to: presentation.id, beforeSlideID: target.id)
                }
                return true
            } else {
                return false
            }
        } else {
            return false
        }
    }

    private func dropSlide(_ payload: String, after target: Slide) -> Bool {
        if let dragged = SlideBulkEdit.draggedSlide(in: payload), dragged.slideID != target.id {
            if dragged.presentationID == presentation.id,
               let source = presentation.slides.first(where: { $0.id == dragged.slideID }) {
                confirmingRepeatedSectionEdit(sections: [source.sectionId, target.sectionId]) {
                    model.moveSlide(presentation.id, slideID: source.id, afterSlideID: target.id)
                }
                return true
            } else if dragged.presentationID != presentation.id,
                      model.presentationExists(dragged.presentationID) {
                confirmingRepeatedSectionEdit(sections: [target.sectionId]) {
                    model.copySlide(
                        dragged.slideID, from: dragged.presentationID,
                        to: presentation.id, afterSlideID: target.id)
                }
                return true
            } else {
                return false
            }
        } else {
            return false
        }
    }

    private func confirmingRepeatedSectionEdit(
        sections sectionIds: [String?], _ apply: @escaping () -> Void
    ) {
        guard let arrangement = effectiveArrangement else {
            apply()
            return
        }
        let repeatedNames = Set(sectionIds.compactMap { $0 })
            .filter { id in arrangement.sectionIds.filter { $0 == id }.count > 1 }
            .map { id in presentation.sections?.first { $0.id == id }?.name ?? "section" }
            .sorted()
        if repeatedNames.isEmpty {
            apply()
        } else {

            let edit = PendingSectionEdit(sectionNames: repeatedNames, apply: apply)
            pendingEdit = nil
            DispatchQueue.main.async { pendingEdit = edit }
        }
    }
}

struct SlideTile: View {
    let model: AppModel
    let render: RenderContext?
    let slide: Slide
    let index: Int

    let aspect: CGFloat
    let presentation: Presentation
    let theme: Theme?
    let arrangementId: String?

    let controls: ServiceControls?

    var isSelected = false
    let roundedCorners: Bool
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    var contextID: String? = nil

    let fire: () -> Void

    /// This tile's own mark (ServiceControls.tileMark): the tile depends on
    /// whether it is live or next and nothing else about the show, so a
    /// fire re-runs only the tiles whose answer changed.
    private var mark: ServiceControls.TileMark {
        controls?.tileMark(contextID: contextID, occurrence: index) ?? ServiceControls.TileMark()
    }

    private var isLive: Bool { mark.isLive }

    private var liveAnimationStep: Int? {
        let mark = mark
        return mark.isLive ? mark.step : nil
    }

    @Environment(\.actionRouter) private var actionRouter

    private var tileShape: RoundedRectangle {
        .standard(roundedCorners ? CornerStandard.element : 0)
    }

    private var section: PresentationSection? {
        guard let id = slide.sectionId, !id.isEmpty else { return nil }
        return presentation.sections?.first { $0.id == id }
    }

    /// The slide's group color, drawn as a thin bar along the tile's bottom
    /// edge; slides outside any group get none.
    private var groupColor: Color? {
        section?.resolvedColorHex(paletteColors: model.groupColors).flatMap(GroupColor.color)
    }

    /// The slide an arrow key fires next, from wherever the live slide is.
    private var isNext: Bool { mark.isNext }

    private var cornerRadius: CGFloat { roundedCorners ? CornerStandard.element : 0 }

    var body: some View {
        let _ = BodyMeter.tick(.slideTile)
        // The slide gets the weight: its group is a thin colored edge, and
        // what it is sits under it as plain text, not a filled strip.
        VStack(alignment: .leading, spacing: SlideGridMetrics.labelGap) {
            SlideThumbnailView(
                model: model, render: render,
                slide: slide, presentation: presentation, theme: theme,
                arrangementId: arrangementId,
                hideScopedBackgrounds: hideScopedBackgrounds,
                legibleText: legibleText
            )
            .aspectRatio(aspect, contentMode: .fit)
            .background(Color.black.opacity(0.35))
            .overlay(alignment: .bottom) {
                if let groupColor {
                    Rectangle().fill(groupColor).frame(height: 3)
                }
            }
            .clipShape(tileShape)
            .overlay { outline }
            // Its own view, so a new suggestion redraws one outline, not every tile.
            .overlay { FollowSuggestionOutline(controls: controls, contextID: contextID, index: index, shape: tileShape) }
            .overlay(alignment: .topLeading) {
                if isLive {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(HopeStyle.live, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
            // The caption is words and badge glyphs with nothing of its own
            // to click or point at (their tooltips are off, tileHelp). Left
            // hit-testable, each of its text runs was a responder SwiftUI
            // walked on every pointer move over the page (StyledTextResponder
            // in the booth's sample). The tile's own shape below still takes
            // the click, the right-click and the drag over the caption.
            label
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: fire)
        // One accessibility element per tile, not one per text run, badge
        // and overlay. Something on the booth Mac reads the window's
        // accessibility tree; on Nov 13 a quarter of the sampled freezes,
        // and one 130 s stretch at full load, were SwiftUI answering it
        // for every view of every tile.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isLive ? "Live, " : "")Slide \(index + 1), \(slideLabel.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { fire() }

        .task(id: stepCountKey) {
            let slide = slide
            let theme = theme
            pagedStepCount = await Task.detached(priority: .utility) {
                PlaceholderAnimations.advanceCount(slide: slide, themes: [theme])
            }.value
        }
    }

    /// Live is a heavy red ring just outside the slide, so it never covers
    /// the picture or the group's edge; next is a quiet ring.
    @ViewBuilder
    private var outline: some View {
        if isLive {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(HopeStyle.live, lineWidth: 3)
                .padding(-3)
                .allowsHitTesting(false)
        } else if isSelected {
            tileShape.strokeBorder(Color.accentColor, lineWidth: 2)
        } else if isNext {
            tileShape.strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
        } else if slide.sourceEvent != nil {
            // Added from hopejc.org: a gold dashed edge, so it's told apart
            // from slides made by hand (right-click › Don't Show This Event).
            tileShape.strokeBorder(HopeStyle.amber, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        } else {
            tileShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
    }

    /// What the slide is, large enough to read from the booth: the
    /// passage, the song's group, the message's point (SlideLabels).
    private var slideLabel: SlideLabel {
        let mediaName = slide.background.flatMap { model.media($0.mediaId)?.name }
        return SlideLabels.label(for: slide, at: index, in: presentation, mediaName: mediaName)
    }

    private var hasBadges: Bool {
        stepCount > 0 || hasAnySteps || slide.autoAdvance != nil || !actionBadges.isEmpty || slide.sourceEvent != nil
    }

    private var label: some View {
        TileCaption(label: slideLabel, number: index + 1, isLive: isLive, hasBadges: hasBadges) {
            badges
        }
    }

    @ViewBuilder
    private var badges: some View {
        if let event = slide.sourceEvent {
            // Added from the church's events page; it comes down by itself.
            Text("hopejc.org")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HopeStyle.amber)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(HopeStyle.amber.opacity(0.18), in: Capsule())
                .tileHelp(WebsiteEventWords.tileHelp(event))
        }
        if stepCount > 0 {
            Text("\(isLive ? 1 + (liveAnimationStep ?? 0) : 0)/\(stepCount + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(isLive ? Color.white : Color.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    (isLive ? HopeStyle.live : Color(.sRGB, white: 0.5).opacity(0.25)),
                    in: Capsule()
                )
                .tileHelp(isLive
                      ? "Click \(1 + (liveAnimationStep ?? 0)) of \(stepCount + 1): the fire was click 1. Advance (or click this tile) is the next; after the last, Advance moves on."
                      : "\(stepCount + 1) clicks on this slide: the fire, then \(stepCount) more step\(stepCount == 1 ? "" : "s").")
        } else if hasAnySteps {

            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(isLive ? HopeStyle.live : Color.secondary)
                .tileHelp("Animation plays on this slide when it fires, with no extra clicks. This includes steps an output's routed theme adds.")
        }

        if let advance = slide.autoAdvance {
            Glyph(kind: .timers, size: 10)
                .foregroundStyle(.secondary)
                .tileHelp(autoAdvanceSummary(advance))
        }

        if !actionBadges.isEmpty {
            let actions = slide.actions ?? []
            HStack(spacing: 3) {

                ForEach(Array(actions.prefix(4)), id: \.id) { action in
                    Glyph(kind: badgeGlyph(action.kind), size: 10)
                        .foregroundStyle(.secondary)
                        .tileHelp(slideActionLabel(
                            action, model: model,
                            timers: actionRouter?.timerChoices ?? [],
                            confidenceScreens: actionRouter?.confidenceScreenChoices ?? []))
                }
                if actionBadges.count > 4 {
                    Text("+\(actionBadges.count - 4)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .tileHelp(actionSummary)
                }
            }
        }
    }


    private var stepCount: Int {
        pagedStepCount ?? TileStepCache.steps(slide: slide, theme: theme).count
    }

    @State private var pagedStepCount: Int?

    private var hasAnySteps: Bool {
        TileStepCache.steps(slide: slide, theme: theme).hasAny
    }

    private struct StepCountKey: Equatable {
        let slide: Slide
        let theme: Theme?
    }

    private var stepCountKey: StepCountKey {
        StepCountKey(slide: slide, theme: theme)
    }

    private var actionBadges: [GlyphKind] {
        (slide.actions ?? []).map { badgeGlyph($0.kind) }
    }

    private func badgeGlyph(_ kind: SlideActionKind) -> GlyphKind {
        switch kind {
        case .switchOutputPreset: .screens
        case .clearLayer, .clearAll, .clearAudio, .clearSignage: .clear
        case .fireMedia: .media
        case .fireAlert, .dismissAlert: .alerts
        case .timerStart, .timerPause, .timerReset, .timerConfigure: .timers
        case .midiOut: .midi
        case .fireCombo: .combos
        case .captureStart, .captureStop: .broadcast
        case .firePresentation: .presentations
        case .setConfidenceLayout, .setStageMode: .confidence
        case .setStreamMode: .screens
        case .listenStart, .listenStop: .confidence
        case .fireServiceItem: .presentations
        case .fireOverlay, .dismissOverlay: .overlays
        case .fireLiveInput: .screens
        case .setSignage: .media
        case .setScreenSource: .screens
        case .enableAudioInput, .disableAudioInput: .audio
        case .fireAudio, .fireAudioPlaylist: .audio
        }
    }

    private func autoAdvanceSummary(_ advance: AutoAdvance) -> String {
        let seconds = advance.delaySeconds
        let interval = seconds == seconds.rounded()
            ? "\(Int(abs(seconds)))s" : String(format: "%.1fs", abs(seconds))
        var text: String
        if advance.afterPlayback ?? false {
            text = if seconds > 0 {
                "Auto Advance: \(interval) after the video ends"
            } else if seconds < 0 {
                "Auto Advance: \(interval) before the video ends"
            } else {
                "Auto Advance: when the video ends"
            }
        } else {
            text = "Auto Advance: after \(interval)"
        }
        if advance.loopToStart ?? false { text += ", loops to the first slide" }
        return text
    }

    private var actionSummary: String {
        (slide.actions ?? []).map {
            slideActionLabel(
                $0, model: model, timers: actionRouter?.timerChoices ?? [],
                confidenceScreens: actionRouter?.confidenceScreenChoices ?? [])
        }.joined(separator: "\n")
    }
}

/// The label under a tile: the slide's number small, what the slide is in
/// 13 pt semibold, and the detail (translation, which point, the lyric's
/// first line) smaller under it, with the slide's badges at the end of that
/// row. A long title gets a second line when there's no detail or badge to
/// make room for; a scripture reference loses its middle, not its end.
struct TileCaption<Badges: View>: View {
    let label: SlideLabel
    var number: Int?
    var isLive = false
    var hasBadges = false
    @ViewBuilder var badges: () -> Badges

    var body: some View {
        let secondRow = label.detail != nil || hasBadges
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isLive ? HopeStyle.live : Color.secondary)
                }
                Text(label.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(secondRow ? 1 : 2)
                    .truncationMode(label.isReference ? .middle : .tail)
            }
            if secondRow {
                HStack(spacing: 4) {
                    if let detail = label.detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    badges()
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: SlideGridMetrics.labelHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TileCaption where Badges == EmptyView {
    init(label: SlideLabel, number: Int? = nil, isLive: Bool = false) {
        self.init(label: label, number: number, isLive: isLive, hasBadges: false) { EmptyView() }
    }
}

@MainActor
func slideActionLabel(
    _ action: SlideAction, model: AppModel,
    timers: [(id: String, name: String)] = [],
    confidenceScreens: [(id: String, name: String)] = []
) -> String {
    func entryName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "not set" }

        return model.indexEntry(id)?.name ?? "missing"
    }
    func timerName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "not set" }
        return timers.first { $0.id == id }?.name ?? "missing"
    }
    func liveInputName(_ action: SlideAction) -> String? {
        if let itemId = action.liveInputId, !itemId.isEmpty {
            return VideoInputInventory.shared.entry(id: itemId)?.name ?? "missing input"
        }

        guard let id = action.inputSourceId, !id.isEmpty else { return nil }
        return LiveInputCatalog.legacyLabel(kind: action.inputSourceKind, id: id)
    }
    func audioInputName(_ action: SlideAction) -> String? {
        guard let id = action.audioInputId, !id.isEmpty else { return nil }
        return AudioInputInventory.shared.name(forId: id) ?? "missing input"
    }
    func configureDetail(_ action: SlideAction) -> String {
        var parts: [String] = []
        switch action.timerMode {
        case .countdown?: parts.append("Countdown")
        case .countdownToTime?:
            let hour = action.timerHour ?? 0
            parts.append("Until \(TimersController.wallLabel(hour: hour, minute: action.timerMinute ?? 0))")
        case .countUp?: parts.append("Count Up")
        case nil: break
        }
        if action.timerMode != .countdownToTime, let seconds = action.timerDurationSeconds, seconds > 0 {
            parts.append(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: " ")))"
    }
    return switch action.kind {
    case .switchOutputPreset:
        "Look: \(entryName(action.presetId))"
    case .clearLayer:
        "Clear \(action.layer.flatMap(LayerKind.init(rawValue:))?.displayName ?? "Layer")"
    case .clearAll: "Clear All"
    case .clearAudio: "Clear Music"
    case .clearSignage: "Clear Signage"
    case .fireMedia: "Fire Media: \(entryName(action.mediaId))"
    case .fireAlert: "Fire Alert: \(entryName(action.alertId))"
    case .dismissAlert: "Dismiss Alert"
    case .timerStart: "Start Timer: \(timerName(action.timerId))"
    case .timerPause: "Pause Timer: \(timerName(action.timerId))"
    case .timerReset: "Reset Timer: \(timerName(action.timerId))"
    case .timerConfigure:
        "Configure Timer: \(timerName(action.timerId))\(configureDetail(action))"
    case .midiOut where PrismScenes.isPrism(action): PrismScenes.label(for: action)
    case .midiOut: "MIDI Out: ch \(action.midiChannel ?? 1)"
    case .fireCombo: "Run Combo: \(entryName(action.comboId))"
    case .captureStart: "Start Capture: \(entryName(action.capturePresetId))"
    case .captureStop:
        action.capturePresetId == nil
            ? "Stop All Capture"
            : "Stop Capture: \(entryName(action.capturePresetId))"
    case .firePresentation:
        "Fire Presentation: \(entryName(action.presentationId))"
    case .setStreamMode:
        "Livestream: \(action.streamMode.flatMap(ShowSetup.StreamMode.init(rawValue:))?.title ?? "—")"
    case .listenStart: "Turn On Microphone"
    case .listenStop: "Turn Off Microphone"
    case .fireServiceItem: "Play Plan Item"
    case .setStageMode:
        "Stage Display: \(action.stageMode.flatMap(ShowSetup.StageMode.init(rawValue:))?.title ?? "—")"
    case .setConfidenceLayout:

        {
            let layout = (action.confidenceLayoutId?.isEmpty ?? true)
                ? "Built-in Layout" : entryName(action.confidenceLayoutId)
            guard let screenId = action.confidenceScreenId, !screenId.isEmpty else {
                return "Confidence Monitor: \(layout)"
            }
            let screen = confidenceScreens.first {
                $0.id.caseInsensitiveCompare(screenId) == .orderedSame
            }?.name ?? "missing screen"
            return "Confidence Monitor: \(layout) on \(screen)"
        }()
    case .fireOverlay: "Fire Overlay: \(entryName(action.overlayId))"
    case .dismissOverlay:
        (action.overlayId?.isEmpty ?? true)
            ? "Take Down Overlays"
            : "Take Down Overlay: \(entryName(action.overlayId))"
    case .fireLiveInput:
        "Fire Live Input: \(liveInputName(action) ?? "not set")"
    case .setSignage:
        (action.playlistId?.isEmpty ?? true)
            ? "Clear Signage"
            : "Signage: \(entryName(action.playlistId))"
    case .setScreenSource:
        (action.signageId?.isEmpty ?? true)
            ? "Screen Source : Program"
            : "Screen Source : Signage"
    case .enableAudioInput:
        "Audio Input On: \(audioInputName(action) ?? "not set")"
    case .disableAudioInput:
        "Audio Input Off: \(audioInputName(action) ?? "not set")"
    case .fireAudio: "Music: \(entryName(action.audioItemId))"
    case .fireAudioPlaylist: "Music Playlist: \(entryName(action.playlistId))"
    }
}

struct SlideThumbnailView: View {
    let model: AppModel
    let render: RenderContext?
    let slide: Slide
    let presentation: Presentation
    let theme: Theme?
    let arrangementId: String?
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    var contentStamp: String? = nil

    @HotDefault("slideGrid.transparencyGrid") private var transparencyGrid = true

    /// The deck's listed stamp, read through the deck's own signal
    /// (AppModel.deckStamp) rather than entry(), which watches the whole
    /// library's list version: a create or edit anywhere re-ran every
    /// thumbnail. Same value as before, so the same cache keys.
    private var updatedStamp: String {
        contentStamp
            ?? "\(model.deckStamp(presentation.id))"
    }

    var body: some View {
        let _ = BodyMeter.tick(.slideThumbnail)
        let source = ThumbnailStore.shared.backgroundSource(
            slideID: slide.id, presentation: presentation,
            arrangementId: arrangementId, stamp: updatedStamp
        )

        let carried = ThumbnailStore.shared.carriedMedia(
            slideID: slide.id, presentation: presentation,
            arrangementId: arrangementId, stamp: updatedStamp, model: model
        )
        let shown = hideScopedBackgrounds ? carried.filter { declaredMediaIDs.contains($0.value) } : carried

        let missing = SlideSceneBuilder.fireMediaPosterIDs(slide: slide) { model.media($0).map { ($0.mediaKind, $0.classification) } }
            .below.filter { model.media($0) == nil }
        ZStack {
            if transparencyGrid {

                TransparencyGrid()
            } else {
                themeBackground
            }

            ForEach([LayerKind.loopingVideos, .stillGraphics].compactMap { shown[$0] } + missing, id: \.self) { id in
                posterLayer(mediaId: id)
            }
            if let content = contentImage() {
                Image(decorative: content, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            if let id = shown[.videos] {
                posterLayer(mediaId: id)
            }
        }
        .overlay(alignment: .bottomLeading) {

            if source?.source == .slide(slide.id) {
                Image(systemName: "film.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .tileHelp("This slide sets the background")
            }
        }
    }

    private var declaredMediaIDs: Set<String> {
        var ids = Set((slide.actions ?? []).filter { $0.kind == .fireMedia }.compactMap(\.mediaId))
        if let own = slide.background?.mediaId, !own.isEmpty { ids.insert(own) }
        return ids
    }

    private var themeBackground: Color {
        if let theme, let color = ColorHex.color(theme.backgroundColorHex) {
            return Color(
                red: color.red, green: color.green, blue: color.blue, opacity: color.alpha
            )
        }
        return .black
    }

    private func posterLayer(mediaId: String) -> some View {
        Color.clear
            .overlay { PosterImage(model: model, mediaId: mediaId) }
            .clipped()
    }

    private func contentImage() -> CGImage? {

        let identity = "\(presentation.id)|\(slide.id)|\(SlideSceneBuilder.lookKey(for: slide, theme: theme))|\(legibleText)"
        let image = ThumbnailStore.shared.slideContent(
            slide: slide, theme: theme,
            render: render, model: model,
            legibleText: legibleText,
            canvas: SlideSceneBuilder.canvasSize(for: presentation),
            cacheKey: "\(identity)|\(updatedStamp)",
            identity: identity,
            mediaEffects: { model.mediaSceneEffects(id: $0) }
        )
        if let image {
            DropLatency.painted(slide.id, detail: "content \(image.width)px")
        }
        return image
    }
}

struct PosterImage: View {
    let model: AppModel
    let mediaId: String

    @State private var image: CGImage?
    @State private var missing = false

    var body: some View {

        let item = model.media(mediaId)
        let stamp = "\(mediaId)|\(item?.fileHash ?? "gone")|\(item.map(MediaPosterStore.posterTime(of:)) ?? 0)"
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(missing ? 0.4 : 1)
            } else {
                Color.black
            }
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Media file missing")
            }
        }
        .task(id: stamp) {
            guard let item = model.media(mediaId) else {

                missing = true
                image = await ThumbnailStore.shared.tombstonePoster(id: mediaId)
                return
            }
            guard let blobs = model.blobs else { return }
            missing = model.isMediaFileMissing(item)
            if !missing, let cached = ThumbnailStore.shared.cachedPoster(for: item) {
                image = cached
                return
            }

            image = nil
            image = await ThumbnailStore.shared.poster(for: item, blobs: blobs)
        }
    }
}

struct AudioFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let audioID: String

    var body: some View {
        if let item = model.audio(audioID) {
            let isLive = controls?.state.liveAudio
                .contains { $0.audioItemId == audioID } ?? false
            let player = controls?.audio.player(forAudioItem: audioID)
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(isLive ? Color.green : .secondary)
                HStack(spacing: 8) {
                    Text(item.name).font(.headline)
                    if isLive {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                if let player, player.duration > 0 {

                    AudioScrubBar(player: player, showsTimes: true)
                        .frame(maxWidth: 360)
                } else if let duration = item.durationSeconds {
                    Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    if isLive {
                        controls?.stopAudio(audioItemID: item.id)
                    } else {
                        controls?.fire(audioItem: item)
                    }
                } label: {
                    Label(
                        isLive ? "Stop" : "Play",
                        systemImage: isLive ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ContentUnavailableView("Music not found", systemImage: "questionmark.square.dashed")
        }
    }
}

struct PlaylistFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let playlistID: String

    var body: some View {
        if let playlist = try? model.playlist(playlistID) {
            let isLive = controls?.state.liveAudio
                .contains { $0.playlistId == playlist.id } ?? false
            VStack(spacing: 16) {
                Image(systemName: isLive ? "waveform" : "music.note.list")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(isLive ? Color.green : .secondary)
                Text(playlist.name).font(.headline)
                VStack(spacing: 2) {
                    ForEach(playlist.entries, id: \.id) { track in
                        let isCurrent = controls?.audio
                            .player(forPlaylist: playlist.id)?.currentEntryID == track.id
                        Button {
                            controls?.fire(playlist: playlist, startAt: track.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "waveform" : "music.note")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.6))
                                    .frame(width: 16)
                                Text(model.entry(track.refId)?.name ?? track.refId)
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let seconds = trackSeconds(track) {
                                    Text(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            isCurrent ? Color.green.opacity(0.10) : Color.primary.opacity(0.03),
                            in: RoundedRectangle.standard(CornerStandard.element)
                        )
                        .tileHelp("Play the playlist starting here")
                    }
                }
                .frame(maxWidth: 440)
                if let player = controls?.audio.player(forPlaylist: playlist.id),
                   player.duration > 0 {

                    AudioScrubBar(player: player, showsTimes: true)
                        .frame(maxWidth: 440)
                }
                Button {
                    if isLive {
                        controls?.stopAudio(playlistID: playlist.id)
                    } else {
                        controls?.fire(playlist: playlist)
                    }
                } label: {
                    Label(
                        isLive ? "Stop" : "Play",
                        systemImage: isLive ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func trackSeconds(_ track: PlaylistEntry) -> Double? {
        switch track.refKind {
        case .audio: model.audio(track.refId)?.durationSeconds
        case .media: model.media(track.refId)?.durationSeconds
        }
    }
}

struct MediaFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let mediaID: String

    var serviceItemID: String? = nil

    @State private var mediaMenuState = MediaCueMenuState()

    @Environment(\.runOnly) private var runOnly

    var body: some View {

        if let item = model.media(mediaID) {
            let isLive = controls?.state.liveMedia.values.contains { $0.mediaId == mediaID } ?? false
            VStack(spacing: 16) {

                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { PosterImage(model: model, mediaId: mediaID) }
                    .frame(maxWidth: 640)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay {
                        if isLive {
                            RoundedRectangle.standard(CornerStandard.element)
                                .strokeBorder(.green, lineWidth: 3)
                        }
                    }
                    .contextMenu {
                        if !runOnly {
                            MediaCueMenuItems(
                                model: model, actionRouter: controls?.actionRouter,
                                mediaID: mediaID, state: mediaMenuState
                            )
                        }
                    }
                HStack(spacing: 8) {
                    Text(item.name).font(.headline)
                    if isLive {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }

                if model.isMediaFileMissing(item) {
                    Label("\u{201C}\(item.fileName)\u{201D} isn't on this Mac", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Button {
                    if let serviceItemID {
                        controls?.fire(mediaItem: item, context: .serviceItem(id: serviceItemID))
                    } else {
                        controls?.fire(mediaItem: item)
                    }
                } label: {
                    Label("Fire", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.isMediaFileMissing(item))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .mediaCueSheets(model: model, state: mediaMenuState)
        } else {

            ContentUnavailableView(
                "Deleted from the library",
                systemImage: "questionmark.square.dashed",
                description: Text(runOnly
                    ? "Unlock run-only to restore a file for it."
                    : "Right-click to restore a file for it — every slide and service using it heals.")
            )
            .contextMenu {
                if !runOnly {
                    MediaCueMenuItems(
                        model: model, actionRouter: controls?.actionRouter,
                        mediaID: mediaID, state: mediaMenuState
                    )
                }
            }
            .mediaCueSheets(model: model, state: mediaMenuState)
        }
    }
}

struct SongKeyChip: View {
    let model: AppModel
    let controls: ServiceControls?
    let presentation: Presentation

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        if let musicKey = presentation.musicKey {
            // Run-only shows the key but can't change it: a transpose
            // rewrites the band's chords on the stage display mid-service.
            if runOnly {
                chipLabel("Key: \(presentation.displayKey ?? musicKey)")
            } else {
                transposeMenu(musicKey: musicKey)
            }
        } else if !runOnly, ChordMath.hasChords(in: presentation) {
            setKeyMenu
        }
    }

    private func transposeMenu(musicKey: String) -> some View {
        let displayed = presentation.displayKey ?? musicKey
        return Menu {
            ForEach(ChordMath.keyChoices(matching: musicKey), id: \.self) { name in
                Button {
                    transpose(to: name, musicKey: musicKey)
                } label: {
                    let original = name.caseInsensitiveCompare(musicKey) == .orderedSame
                    if name.caseInsensitiveCompare(displayed) == .orderedSame {
                        Label(original ? "\(name) (Original)" : name, systemImage: "checkmark")
                    } else {
                        Text(original ? "\(name) (Original)" : name)
                    }
                }
            }
        } label: {
            chipLabel("Key: \(displayed)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func transpose(to name: String, musicKey: String) {
        model.updatePresentationField(
            presentation.id, \.displayKey, key: "displayKey",
            to: name.caseInsensitiveCompare(musicKey) == .orderedSame ? nil : name,
            undoLabel: "Transpose")
        controls?.presentationEdited(presentation.id)
    }

    private var setKeyMenu: some View {
        Menu {
            ForEach(ChordMath.keyChoices(matching: "C"), id: \.self) { name in
                Button(name) { setKey(name) }
            }
            Divider()
            ForEach(ChordMath.keyChoices(matching: "Am"), id: \.self) { name in
                Button(name) { setKey(name) }
            }
        } label: {
            chipLabel("Key: Set…")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tileHelp("This song has chords but no key yet — pick the key they're written in")
    }

    private func setKey(_ name: String) {
        model.updatePresentationField(presentation.id, \.musicKey, key: "musicKey", to: name, undoLabel: "Set Key")
        controls?.presentationEdited(presentation.id)
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct SlideShowChip: View {
    let model: AppModel
    let controls: ServiceControls?
    let presentation: Presentation

    @Environment(\.runOnly) private var runOnly
    @State private var sheetPresented = false

    var body: some View {
        if let slideShow = presentation.autoAdvance {
            if runOnly {
                chipLabel(text(slideShow))
            } else {
                Button {
                    sheetPresented = true
                } label: {
                    chipLabel(text(slideShow))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .sheet(isPresented: $sheetPresented) {
                    AutoAdvanceSheet(
                        slideName: presentation.name,
                        advance: Binding(
                            get: { model.presentation(presentation.id)?.autoAdvance },
                            set: { advance in
                                model.updatePresentationField(
                                    presentation.id, \.autoAdvance, key: "autoAdvance", to: advance,
                                    undoLabel: "Slide Show")
                                controls?.presentationEdited(presentation.id)
                            }
                        ),
                        presentationScope: true
                    )
                }
            }
        }
    }

    private func text(_ slideShow: AutoAdvance) -> String {
        let seconds = slideShow.delaySeconds
        let interval = seconds == seconds.rounded()
            ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
        return "Slide Show: \(interval)\((slideShow.loopToStart ?? false) ? " · Loop" : "")"
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// Lyric follow for one song, beside its name: turns following on, and shows
/// what it's doing (Listening, Next: 6 Chorus, Paused). Only on songs.
struct LyricFollowChip: View {
    let controls: ServiceControls?
    let presentation: Presentation

    @Environment(\.openWindow) private var openWindow

    private enum Shown: Equatable { case off, starting, micOff, sermonMic, listening, next(String), paused }

    private var shown: Shown {
        let assist = LiveAssist.shared
        guard assist.isFollowing(presentation.id) else { return .off }
        if assist.sermonMicInUse { return .sermonMic }
        if assist.starting { return .starting }
        guard assist.hearsWorship else { return .micOff }
        guard controls?.state.liveSlide?.presentation?.id == presentation.id else { return .listening }
        if assist.isPaused { return .paused }
        if let suggestion = assist.suggestion, suggestion.presentationID == presentation.id,
           controls?.liveContextID == suggestion.contextID, controls?.liveOccurrence == suggestion.fromOccurrence {
            return .next(suggestion.label)
        }
        return .listening
    }

    var body: some View {
        if LiveAssist.isSong(presentation) {
            let assist = LiveAssist.shared
            let shown = shown
            Menu {
                Toggle("Follow This Song", isOn: Binding(
                    get: { assist.followedSongIDs.contains(presentation.id) },
                    set: { _ in assist.toggleFollow(presentation) }))
                Toggle("Follow Every Song", isOn: Binding(
                    get: { assist.followsEverySong }, set: { assist.followsEverySong = $0 }))
                Toggle("Advance Automatically", isOn: Binding(
                    get: { assist.advancesAutomatically }, set: { assist.advancesAutomatically = $0 }))
                Divider()
                if shown == .sermonMic {
                    Button("Use the Worship Mic") { assist.listenForLyrics(overSermon: true) }
                }
                if assist.listening {
                    Button("Stop Listening") { assist.stop() }
                }
                Button("Live Assist…") { openWindow(id: "liveAssist") }
            } label: {
                label(shown)
            } primaryAction: {
                primary(shown)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(help(shown, status: assist.status))
        }
    }

    private func primary(_ shown: Shown) {
        let assist = LiveAssist.shared
        switch shown {
        case .off: assist.toggleFollow(presentation)
        case .micOff: assist.listenForLyrics()
        case .sermonMic: assist.listenForLyrics(overSermon: true)
        default:
            if assist.followedSongIDs.contains(presentation.id) {
                assist.toggleFollow(presentation)
            } else {
                assist.followsEverySong = false
            }
        }
    }

    private func label(_ shown: Shown) -> some View {
        let (text, tint): (String, Color?) = switch shown {
        case .off: ("Follow", nil)
        case .starting: ("Starting…", .secondary)
        case .micOff: ("Follow: Mic Off", .orange)
        case .sermonMic: ("Follow: Sermon Mic in Use", .orange)
        case .listening: ("Listening", .green)
        case .next(let slide): ("Next: \(slide)", HopeStyle.teal)
        case .paused: ("Paused", .orange)
        }
        return Label(text, systemImage: shown == .off ? "waveform" : "waveform.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.map { AnyShapeStyle($0.opacity(0.15)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
    }

    private func help(_ shown: Shown, status: String) -> String {
        switch shown {
        case .off: "Follow this song: listen to the worship mic and outline the next slide as it's sung"
        case .micOff: "\(status). Click to listen again."
        case .sermonMic: "The sermon mic is listening for scripture. Click to switch to the worship mic; scripture detection stops."
        case .paused: "Paused for 8 s after a slide was changed by hand"
        default: "Following this song. Click to stop. Changing a slide by hand pauses it for 8 s."
        }
    }
}

/// The slide lyric follow expects next: a pulsing dashed outline, apart from
/// the live slide's solid red one.
struct FollowSuggestionOutline: View {
    let controls: ServiceControls?
    let contextID: String?
    let index: Int
    let shape: RoundedRectangle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    /// The suggestion is read first, so with none up no tile watches the live slide here.
    private var shows: Bool {
        guard let suggestion = LiveAssist.shared.suggestion, let contextID,
              suggestion.contextID == contextID, suggestion.slideIndex == index, let controls
        else { return false }
        return controls.liveContextID == contextID && controls.liveOccurrence == suggestion.fromOccurrence
    }

    var body: some View {
        if shows {
            shape.strokeBorder(HopeStyle.teal, style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                .opacity(dim ? 0.35 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
                .onAppear { dim = true }
                .allowsHitTesting(false)
        }
    }
}

/// A slide grid's right-click menu, built when it is opened, for the tile
/// the click was over (SlideGridMenuPress). Written inline in
/// `.contextMenu { … }`, SwiftUI calls that closure every time the view
/// updates and built the whole menu (screens, layouts, livestream designs,
/// themes, actions) on every pass: a tenth of the booth's tile-body time
/// when each tile had its own. Inside a view of its own, the closure only
/// makes this small value and the items are built from its body when the
/// menu is shown. The items are SlideGridBody.tileMenu, as they always were.
private struct GridMenuContent: View {
    let grid: SlideGridBody
    let press: SlideGridMenuPress

    var body: some View {
        if let index = press.tile(), grid.slides.indices.contains(index) {
            #if DEBUG || MXU_PERF_HOOKS
            let _ = DiagnosticsStore.shared.note(
                "perf.menu.built", detail: "\(grid.contextID) tile \(index) \(grid.slides[index].id)")
            #endif
            grid.tileMenu(index: index, slide: grid.slides[index])
        }
    }
}

extension View {
    @ViewBuilder
    func tileHelp(_ text: @autoclosure () -> String) -> some View {
        self
    }
}

/// The plan page's selection box: dragged from any empty space on the
/// page, it selects the slides under it in every item's grid, so a run of
/// slides across items can be copied, cut or deleted together.
@MainActor
@Observable
final class PageMarquee {
    /// In the page's content coordinates; nil when no box is being dragged.
    private(set) var rect: CGRect?

    /// The item whose grid holds the selection after a click there; every
    /// other grid lets its own go, so Delete, ⌘X and ⌘C never reach slides
    /// left selected in an item scrolled away. Nil after a box, which
    /// selects across items.
    private(set) var owner: String?

    func own(_ contextID: String) {
        if owner != contextID { owner = contextID }
    }

    func gesture(in space: CoordinateSpace, enabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: space)
            .onChanged { [weak self] value in
                guard enabled else { return }
                self?.update(start: value.startLocation, location: value.location)
            }
            .onEnded { [weak self] _ in self?.end() }
    }

    func update(start: CGPoint, location: CGPoint) {
        if owner != nil { owner = nil }
        rect = CGRect(
            x: min(start.x, location.x), y: min(start.y, location.y),
            width: abs(location.x - start.x), height: abs(location.y - start.y))
    }

    func end() { rect = nil }

    static func box(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay { Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

extension EnvironmentValues {
    @Entry var pageMarquee: PageMarquee?
}

/// Hands a grid the page's box in the grid's own coordinates, and tells it
/// when a click in another item takes the selection.
private struct PageMarqueeFollow: ViewModifier {
    let pageMarquee: PageMarquee?
    let contextID: String
    let onBox: (CGRect) -> Void
    let onOtherOwner: () -> Void
    @State private var origin: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGPoint.self) {
                $0.frame(in: .named(ServiceContinuousView.contentSpace)).origin
            } action: { origin = $0 }
            .onChange(of: pageMarquee?.rect) { _, rect in
                guard let rect else { return }
                onBox(rect.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            .onChange(of: pageMarquee?.owner) { _, owner in
                if let owner, owner != contextID { onOtherOwner() }
            }
    }
}

/// Where a plan page grid is, as far as the page cares: rows near the
/// screen (and the wider band kept built), its size, and its top in the
/// page's content. Equal values mean nothing to do, so a scroll that
/// doesn't bring a row in or out costs no work beyond working this out.
struct GridPlace: Equatable, Sendable {
    var docTop: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    /// The rows to build, to keep built, and on screen. While the page
    /// glides to a picked item these are for where it will land.
    var near: Range<Int> = 0 ..< 0
    var keep: Range<Int> = 0 ..< 0
    var visible: Range<Int> = 0 ..< 0
    var gliding = false
    /// The same for where the grid is now, glide or not.
    var actualNear: Range<Int> = 0 ..< 0
    var actualKeep: Range<Int> = 0 ..< 0
    var actualVisible: Range<Int> = 0 ..< 0

    static func of(
        _ proxy: GeometryProxy, rowPitch: CGFloat?, across: Int, count: Int, buildsNear: Bool
    ) -> GridPlace {
        var place = GridPlace(
            docTop: proxy.frame(in: .named(ServiceContinuousView.contentSpace)).minY,
            width: proxy.size.width, height: proxy.size.height)
        // The scroll view in the grid's own space: its top is the grid's
        // distance below the top of the screen, negated.
        if buildsNear, let rowPitch, let visible = proxy.bounds(of: .named(ServiceContinuousView.scrollSpace)) {
            let rows = (count + across - 1) / max(1, across)
            func band(_ gridTop: CGFloat, _ screens: CGFloat) -> Range<Int> {
                SlidesAcross.nearRows(
                    gridTop: gridTop, rowPitch: rowPitch, rowCount: rows,
                    viewport: visible.height, margin: visible.height * screens)
            }
            place.actualVisible = band(-visible.minY, 0)
            place.actualNear = band(-visible.minY, 1)
            place.actualKeep = band(-visible.minY, 2)
            if let landing = PageGlide.shared.landingTop {
                // Where the grid will be once the page has landed.
                let gridTop = place.docTop - landing
                place.gliding = true
                place.visible = band(gridTop, 0)
                place.near = band(gridTop, 1)
                place.keep = band(gridTop, 2)
            } else {
                place.visible = place.actualVisible
                place.near = place.actualNear
                place.keep = place.actualKeep
            }
        }
        return place
    }
}

/// A plan page grid's rows: which are built as tiles, which are wanted,
/// and its turn at the page's pace (RowBuildPacer).
@MainActor final class RowBuildQueue {
    /// The rows built as tiles; each row's view reads its own flag.
    private(set) var built: Set<Int> = []
    private var flags: [Int: GridRowFlag] = [:]
    /// The rows wanted built.
    var target: Set<Int> = []
    /// The rows on screen (or about to be): the nearest missing row to
    /// these is built first.
    var focus: Range<Int> = 0 ..< 0
    var place = GridPlace()

    func flag(_ row: Int) -> GridRowFlag {
        if let flag = flags[row] { return flag }
        let flag = GridRowFlag()
        flags[row] = flag
        return flag
    }

    /// Never animated: rows come in while the page glides to an item, and
    /// inside that animation each new tile would fade in.
    func setBuilt(_ rows: Set<Int>) {
        guard rows != built else { return }
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            for row in built.symmetricDifference(rows) { flag(row).built = rows.contains(row) }
        }
        #if DEBUG || MXU_PERF_HOOKS
        RowBuildLog.note(added: rows.subtracting(built).count, removed: built.subtracting(rows).count)
        #endif
        built = rows
    }

    var settled: Bool { built == target }

    /// How far the nearest missing row is from the screen, in rows; nil
    /// with none missing. A grid nowhere near the screen comes after any
    /// that is.
    var buildDistance: Int? {
        nearest(of: target.subtracting(built)).map { (focus.isEmpty ? 10_000 : 0) + distance($0) }
    }

    /// One change toward the rows wanted: the nearest missing row built
    /// or, with none missing, the farthest row no longer wanted let go.
    func step() {
        if let next = nearest(of: target.subtracting(built)) {
            setBuilt(built.union([next]))
        } else if let last = farthest(of: built.subtracting(target)) {
            setBuilt(built.subtracting([last]))
        }
    }

    private func nearest(of rows: Set<Int>) -> Int? {
        rows.min { distance($0) < distance($1) || (distance($0) == distance($1) && $0 < $1) }
    }

    private func farthest(of rows: Set<Int>) -> Int? {
        rows.max { distance($0) < distance($1) || (distance($0) == distance($1) && $0 < $1) }
    }

    private func distance(_ row: Int) -> Int {
        if focus.isEmpty { return row }
        if row < focus.lowerBound { return focus.lowerBound - row }
        if row >= focus.upperBound { return row - focus.upperBound + 1 }
        return 0
    }
}

/// Whether one row of a plan page grid is built as tiles.
@MainActor @Observable final class GridRowFlag {
    var built = false
}

/// One row of a slide grid: its tiles once built, else empty cells of the
/// same size. Reads only its own flag.
private struct GridRowSwitch<Built: View, Empty: View>: View {
    let flag: GridRowFlag
    /// The grid knows its cell size (it has been measured).
    let ready: Bool
    @ViewBuilder let built: () -> Built
    @ViewBuilder let empty: () -> Empty

    var body: some View {
        if ready, flag.built {
            built()
        } else {
            empty()
        }
    }
}

/// The plan page's pace for making and letting go of rows of tiles: one
/// row, in one grid, per frame. A row of tiles takes several milliseconds
/// to make; grids stepping on their own made a 30 to 50 ms frame wherever
/// several had rows to make at once (a glide landing among them). The grid
/// with a missing row nearest the screen goes first; rows are let go only
/// when none is waiting to be made, so tidying up behind a glide never
/// holds up the rows it is landing on.
@MainActor final class RowBuildPacer {
    static let shared = RowBuildPacer()

    /// About a frame at 60 Hz.
    static let pace: TimeInterval = 0.016
    /// Rows around the screen, not on it, are made once the operator has
    /// paused this long, and this far apart: making a row is a 30 ms
    /// frame, which nobody sees with nothing moving.
    static let idleAfter: TimeInterval = 0.5
    static let idlePace: TimeInterval = 0.05
    private var waiting: [RowBuildQueue] = []
    private var scheduled = false
    private var last: TimeInterval = 0

    func request(_ queue: RowBuildQueue) {
        guard !queue.settled else { return }
        if !waiting.contains(where: { $0 === queue }) { waiting.append(queue) }
        schedule(after: Self.pace)
    }

    /// Never run at once: every grid on the page asks in the same frame,
    /// and the nearest should go first, not the first to ask.
    private func schedule(after gap: TimeInterval) {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0.001, last + gap - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            scheduled = false
            run()
        }
    }

    /// The page gliding to a pick, or picked, clicked or fired on a moment
    /// ago: the rows around the screen can wait. Not the operator's own
    /// scrolling: there the rows ahead are what is coming next, and they
    /// keep being made, a row a frame, so the scroll never reaches empty
    /// cells.
    private var operatorBusy: Bool {
        if PageGlide.shared.landingTop != nil { return true }
        let input = InputTrailRecorder.shared
        if let scroll = input.sincePageScroll(), scroll < 0.2 { return false }
        return [input.sinceKey(), input.sinceClick(), input.sinceFocusScroll()]
            .contains { ($0 ?? .infinity) < Self.idleAfter }
    }

    private func run() {
        waiting.removeAll { $0.settled }
        let next = waiting.min { (a, b) in
            (a.buildDistance ?? .max) < (b.buildDistance ?? .max)
        }
        guard let next else { return }
        // A missing row on screen (or where a glide lands) is made now;
        // anything else waits for a pause.
        let urgent = next.buildDistance == 0
        if !urgent, operatorBusy {
            last = ProcessInfo.processInfo.systemUptime
            schedule(after: 0.1)
            return
        }
        last = ProcessInfo.processInfo.systemUptime
        next.step()
        waiting.removeAll { $0.settled }
        let scrolling = (InputTrailRecorder.shared.sincePageScroll() ?? .infinity) < 0.2
        if !waiting.isEmpty { schedule(after: urgent || scrolling ? Self.pace : Self.idlePace) }
    }
}

/// The page's glide to a picked item: where it will land, until it has.
/// The grids read it as they are placed (their geometry closures can run
/// off the main thread, hence the lock), so they build the rows the page
/// is going to rather than every row it passes on the way.
final class PageGlide: Sendable {
    static let shared = PageGlide()

    private let state = OSAllocatedUnfairLock<(top: CGFloat, until: TimeInterval)?>(initialState: nil)

    /// The top of the screen, in the page's content, where the glide lands.
    var landingTop: CGFloat? {
        state.withLock { glide in
            guard let glide, ProcessInfo.processInfo.systemUptime < glide.until else { return nil }
            return glide.top
        }
    }

    func begin(landingTop: CGFloat, duration: TimeInterval) {
        state.withLock { $0 = (landingTop, ProcessInfo.processInfo.systemUptime + duration) }
        #if DEBUG || MXU_PERF_HOOKS
        Task { @MainActor in RowBuildLog.begin() }
        #endif
    }

    func end() {
        state.withLock { $0 = nil }
    }
}

/// Counts the page's glides as they end, for the grids to put their rows
/// back around where they are.
@MainActor @Observable final class PageGlideEnds {
    static let shared = PageGlideEnds()
    private(set) var count = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The glide just begun is over after `duration` (and a frame or two).
    func expect(after duration: TimeInterval) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            guard !Task.isCancelled else { return }
            PageGlide.shared.end()
            #if DEBUG || MXU_PERF_HOOKS
            RowBuildLog.landed()
            #endif
            self?.count += 1
        }
    }
}

/// Runs `ended` when a glide ends; a modifier of its own so the grid's body
/// doesn't read the count.
private struct PageGlideEndFollow: ViewModifier {
    let active: Bool
    let ended: () -> Void

    func body(content: Content) -> some View {
        if active {
            content.onChange(of: PageGlideEnds.shared.count) { _, _ in ended() }
        } else {
            content
        }
    }
}

/// A tile's animation steps, worked out once per slide and theme. Counting
/// builds the slide's whole composition two or three times over, and the
/// caption asked on every pass of every tile.
@MainActor
enum TileStepCache {
    private struct Entry {
        let slide: Slide
        let theme: Theme?
        let count: Int
        let hasAny: Bool
    }

    private static var entries: [String: Entry] = [:]

    static func steps(slide: Slide, theme: Theme?) -> (count: Int, hasAny: Bool) {
        // Equal values from the library share storage, so these compare fast.
        if let entry = entries[slide.id], entry.slide == slide, entry.theme == theme {
            return (entry.count, entry.hasAny)
        }
        let count = PlaceholderAnimations.advanceCount(slide: slide, themes: [theme], paging: false)
        let hasAny = PlaceholderAnimations.hasAnimationSteps(slide: slide, themes: [theme])
        if entries.count > 5000 { entries.removeAll(keepingCapacity: true) }
        entries[slide.id] = Entry(slide: slide, theme: theme, count: count, hasAny: hasAny)
        return (count, hasAny)
    }
}


/// Where a drop on a slide grid would land (SlideGridBody.dropMarks).
@MainActor
@Observable
final class GridDropMarks {
    private(set) var target: SlideDropPlacement.Target?
    /// After a drop the grid moves under the pointer and the drag's last
    /// updates can still arrive: no mark is shown for them.
    @ObservationIgnored private var settleUntil = Date.distantPast

    func show(_ target: SlideDropPlacement.Target?) {
        if target != nil, Date() < settleUntil { return }
        if self.target != target { self.target = target }
    }

    func clear() {
        if target != nil { target = nil }
    }

    func settle() {
        settleUntil = Date().addingTimeInterval(0.6)
        clear()
    }
}

/// The grid's drop mark, drawn over the tile it is for. One layer for the
/// grid: an overlay on each tile was one more thing made for every tile of
/// every row built.
private struct GridDropMarkLayer: View {
    let marks: GridDropMarks
    let frame: (Int) -> CGRect?

    var body: some View {
        if let target = marks.target, let frame = frame(target.index) {
            TileDropMarks(
                before: target == .before(target.index),
                after: target == .after(target.index),
                onto: target == .onto(target.index))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Where a dragged slide or picture would land on a tile: a line before or
/// after it, or a ring for onto it.
private struct TileDropMarks: View {
    let before: Bool
    let after: Bool
    let onto: Bool

    var body: some View {
        if before || after || onto {
            ZStack {
                if before {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 14)
                        .offset(x: -7.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if after {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 14)
                        .offset(x: 7.5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if onto {
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.9), lineWidth: 2)
                }
            }
        }
    }
}

/// A tile telling its grid where it is, for a grid that can't work it out
/// (no cell size yet).
private struct TileFrameReport: ViewModifier {
    let box: TileFrameBox?
    let index: Int

    func body(content: Content) -> some View {
        if let box {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("slideGrid")) } action: { frame in
                    box.frames[index] = frame
                }
                .onDisappear { box.frames.removeValue(forKey: index) }
        } else {
            content
        }
    }
}

/// A slide grid's tile frames (see `SlideGridBody.tileFrameBox`).
@MainActor final class TileFrameBox {
    var frames: [Int: CGRect] = [:]
}

#if DEBUG || MXU_PERF_HOOKS
/// When rows of tiles were made and let go after each glide began, for the
/// perf scenarios: "perf.rows — 18:+1 34:+1 … | 352:landed | 368:+1 -0".
@MainActor enum RowBuildLog {
    private static var start: TimeInterval = 0
    private static var entries: [String] = []
    private static var flush: Task<Void, Never>?

    static func begin() {
        dump()
        start = ProcessInfo.processInfo.systemUptime
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { dump() }
        }
    }

    static func note(added: Int, removed: Int) {
        guard start > 0 else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        entries.append("\(ms):" + (added > 0 ? "+\(added)" : "") + (removed > 0 ? "-\(removed)" : ""))
    }

    static func landed() {
        guard start > 0 else { return }
        entries.append("\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)):landed")
    }

    private static func dump() {
        if !entries.isEmpty { DiagnosticsStore.shared.note("perf.rows", detail: entries.joined(separator: " ")) }
        entries = []
    }
}
#endif
