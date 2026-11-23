import AppKit
import PresenterCore
import SwiftUI

@MainActor
final class InputTrailRecorder {
    static let shared = InputTrailRecorder()

    private var trail = InputTrail()
    private var monitor: Any?

    private var lastFocusScroll: TimeInterval?

    /// The page's own input, kept apart from the trail: the trail holds four
    /// entries, so typing a stage message would push a scroll out of it.
    private var lastPageScroll: TimeInterval?
    private var lastPageClick: TimeInterval?
    private var lastGridScroll: TimeInterval?
    private var lastGridClick: TimeInterval?
    private var lastKeyboardFire: TimeInterval?

    private let regions = NSHashTable<InputRegionView>.weakObjects()

    private init() {}

    func activate() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            ) { event in
                MainActor.assumeIsolated { InputTrailRecorder.shared.take(event) }
                return event
            }
        }
    }

    func record(_ what: String) {
        trail.record(what, at: ProcessInfo.processInfo.systemUptime)
    }

    #if DEBUG || MXU_PERF_HOOKS
    /// The perf scroll signal's wheel events go straight to the scroll
    /// view, past the event monitor that notes a real one.
    func notePerfPageScroll() {
        lastPageScroll = ProcessInfo.processInfo.systemUptime
        PageScrolling.shared.wheel()
    }
    #endif

    func noteFocusScroll() {
        lastFocusScroll = ProcessInfo.processInfo.systemUptime
    }

    /// A key put a slide up (an arrow on the page, the clicker, a hot key).
    func noteKeyboardFire() {
        lastKeyboardFire = ProcessInfo.processInfo.systemUptime
    }

    func cause() -> String {
        "input: \(trail.summary(at: ProcessInfo.processInfo.systemUptime)); keys go to \(focusDescription())"
    }

    func sinceScroll() -> TimeInterval? {
        trail.age(of: "scroll", at: ProcessInfo.processInfo.systemUptime)
    }

    /// A scroll over the whole-plan page itself, not the plan list beside it.
    func sincePageScroll() -> TimeInterval? {
        lastPageScroll.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// A slide put up from the keyboard. Keys that only type, into the
    /// stage message or a search field, don't count.
    func sinceKey() -> TimeInterval? {
        lastKeyboardFire.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// A click on the whole-plan page. One in the plan list or a sheet
    /// didn't put the slide under the pointer.
    func sinceClick() -> TimeInterval? {
        lastPageClick.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// A scroll over one song's grid (Show Whole Plan off, or the library).
    func sinceGridScroll() -> TimeInterval? {
        lastGridScroll.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// A click on one song's grid.
    func sinceGridClick() -> TimeInterval? {
        lastGridClick.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    func sinceFocusScroll() -> TimeInterval? {
        lastFocusScroll.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    fileprivate func register(_ view: InputRegionView) {
        regions.add(view)
    }

    private func take(_ event: NSEvent) {
        let what: String
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = InputTrail.keyName(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                command: flags.contains(.command), option: flags.contains(.option),
                control: flags.contains(.control), shift: flags.contains(.shift))
            what = "key \(key)\(event.isARepeat ? " held" : "") to \(focusDescription())"
        case .scrollWheel:
            let place = region(at: event.locationInWindow, in: event.window)
            if place == Self.page {
                lastPageScroll = now
                PageScrolling.shared.wheel()
            }
            if place == Self.grid { lastGridScroll = now }
            what = "scroll in \(place)"
        case .rightMouseDown:
            PageScrolling.shared.pointerDown()
            what = "right-click in \(region(at: event.locationInWindow, in: event.window))"
        case .otherMouseDown:
            what = "other-click in \(region(at: event.locationInWindow, in: event.window))"
        default:
            PageScrolling.shared.pointerDown()
            let click = event.clickCount > 1 ? "double-click" : "click"
            let place = region(at: event.locationInWindow, in: event.window)
            if place == Self.page { lastPageClick = now }
            if place == Self.grid { lastGridClick = now }
            what = "\(click) in \(place)"
        }

        trail.record(what, at: now)
    }

    /// The whole-plan page's region name (ServiceContinuousView).
    private static let page = "present"
    /// One song's grid (PresentGridView).
    static let grid = "single deck"

    private func region(at point: NSPoint, in window: NSWindow?) -> String {
        let hits = regions.allObjects.filter { view in
            view.window != nil && view.window === window && !view.isHiddenOrHasHiddenAncestor
                && view.covers(point)
        }
        let smallest = hits.min { $0.area.width * $0.area.height < $1.area.width * $1.area.height }
        return smallest?.name ?? "elsewhere (\(window?.identifier?.rawValue ?? "no window"))"
    }

    private func focusDescription() -> String {
        let responder = NSApp.keyWindow?.firstResponder
        if let view = responder as? NSView {
            let rect = view.convert(view.visibleRect, to: nil)
            let place = region(at: NSPoint(x: rect.midX, y: rect.midY), in: view.window)
            return "\(place) (\(String(describing: type(of: view)).prefix(40)))"
        } else {
            return responder.map { String(describing: type(of: $0)).prefix(40).description } ?? "nothing"
        }
    }
}

final class InputRegionView: NSView {
    var name = ""
    var area = CGSize.zero

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { InputTrailRecorder.shared.register(self) }
    }

    func covers(_ windowPoint: NSPoint) -> Bool {
        CGRect(origin: .zero, size: area).contains(convert(windowPoint, from: nil))
    }
}

private struct InputRegionMarker: NSViewRepresentable {
    let name: String
    let area: CGSize

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InputRegionView, context: Context) -> CGSize? {
        .zero
    }

    func makeNSView(context: Context) -> InputRegionView {
        let view = InputRegionView()
        view.name = name
        view.area = area
        return view
    }

    func updateNSView(_ nsView: InputRegionView, context: Context) {
        nsView.name = name
        nsView.area = area
    }
}

extension View {

    func inputRegion(_ name: String) -> some View {
        background(alignment: .topLeading) {
            GeometryReader { proxy in
                InputRegionMarker(name: name, area: proxy.size)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

struct PresentScrollWatch: NSViewRepresentable {
    func makeNSView(context: Context) -> PresentScrollWatchView { PresentScrollWatchView() }
    func updateNSView(_ nsView: PresentScrollWatchView, context: Context) {}
}

final class PresentScrollWatchView: NSView {
    private var observers: [NSObjectProtocol] = []
    private weak var watched: NSScrollView?
    private var lastOffset: CGFloat?
    private var lastHeight: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch(window == nil ? nil : enclosingScrollView)
    }

    private func watch(_ scrollView: NSScrollView?) {
        if scrollView !== watched {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            watched = scrollView
            PresentCardFrames.shared.scrollView = scrollView
            lastOffset = nil
            lastHeight = nil
            if let scrollView {
                let center = NotificationCenter.default
                scrollView.contentView.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.moved() }
                })
                if let document = scrollView.documentView {
                    document.postsFrameChangedNotifications = true
                    observers.append(center.addObserver(
                        forName: NSView.frameDidChangeNotification, object: document, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.resized() }
                    })
                }
            } else if window != nil {
                DiagnosticsStore.shared.note("present.jump", detail: "no scroll view to watch")
            }
        }
    }

    private var offsetFromTop: CGFloat {
        PresentCardFrames.offsetFromTop(watched)
    }

    private func moved() {
        PresentCardFrames.shared.moved()
        PresentCardFrames.shared.captureHold()
        if let clip = watched?.contentView {
            let offset = offsetFromTop
            let recorder = InputTrailRecorder.shared
            if let last = lastOffset,
               PresentJumpRule.isUnprompted(
                   delta: offset - last, viewport: clip.bounds.height,
                   sinceScroll: recorder.sinceScroll(), sinceFocus: recorder.sinceFocusScroll()) {
                DiagnosticsStore.shared.note(
                    "present.jump",
                    detail: "top \(Int(last)) → \(Int(offset)) pt of \(Int(watched?.documentView?.frame.height ?? 0))"
                        + " (viewport \(Int(clip.bounds.height))); \(recorder.cause())")
            }
            lastOffset = offset
        }
    }

    private func resized() {
        if let height = watched?.documentView?.frame.height, let clip = watched?.contentView {
            let offset = offsetFromTop
            if let last = lastHeight,
               PresentJumpRule.isReflow(delta: height - last, offset: offset, viewport: clip.bounds.height) {
                DiagnosticsStore.shared.note(
                    "present.reflow",
                    detail: "content \(Int(last)) → \(Int(height)) pt with top at \(Int(offset))"
                        + "; \(InputTrailRecorder.shared.cause())")
            }
            lastHeight = height
        }
    }
}

@MainActor
final class PresentCardFrames {
    static let shared = PresentCardFrames()

    /// Where the page's content sits in the scroll view, measured once per
    /// scroll frame. Each item's place on screen is its place in the content
    /// (which only changes when the page lays out again) plus this, so a
    /// scroll measures one view instead of every item and every grid.
    var contentOrigin: CGPoint = .zero

    /// An item's frame in the scroll view's space.
    func frame(_ id: String) -> CGRect? {
        docFrames[id]?.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
    }

    weak var scrollView: NSScrollView?

    private var rows: [(id: String, name: String)] = []

    /// Plan headers: bands on the page, never the item it is showing.
    private var headerIDs: Set<String> = []

    /// Told the item the operator is looking at as they scroll the page, so
    /// the plan list can highlight it.
    var onOperatorScroll: ((String) -> Void)?

    /// The page's visible height, for the line a third of the way down that
    /// decides which item the operator is looking at.
    var viewportHeight: CGFloat = 0
    private var readingLine: CGFloat { viewportHeight > 0 ? viewportHeight / 3 : 1 }

    private var anchor: PresentLanding.Anchor?
    private var settleTask: Task<Void, Never>?
    private var keepTask: Task<Void, Never>?

    private var keepingUntil: TimeInterval = 0

    private var docFrames: [String: CGRect] = [:]

    private var hold: (id: String, top: CGFloat, width: CGFloat, heights: [String: CGFloat])?
    private var holdScheduled = false

    private var holdPinnedUntil: TimeInterval = 0

    private var holdCorrections: [TimeInterval] = []

    private init() {}

    /// The page is about to glide to `id`: tells the grids where it will
    /// land (PageGlide), the top of that item, or as far as the page can
    /// scroll when the item is near its end.
    func beginGlide(to id: String, duration: TimeInterval) {
        guard let top = docFrames[id]?.minY else { return }
        var landing = top
        if let scrollView, let document = scrollView.documentView {
            landing = min(top, max(0, document.frame.height - scrollView.contentView.bounds.height))
        }
        PageGlide.shared.begin(landingTop: landing, duration: duration + 0.05)
        PageGlideEnds.shared.expect(after: duration)
    }

    func noteDoc(_ id: String, _ frame: CGRect) {
        if docFrames[id] != frame {
            docFrames[id] = frame
            scheduleHold()
        }
    }

    func captureHold() {
        if !holdScheduled, ProcessInfo.processInfo.systemUptime >= holdPinnedUntil,
           let card = PresentLanding.cardAtTop(cards), let top = docFrames[card.id]?.minY,
           let width = scrollView?.contentView.bounds.width {
            hold = (card.id, top, width, heights)
        }
    }

    func holdCard(_ id: String) {
        if let top = docFrames[id]?.minY, let width = scrollView?.contentView.bounds.width {
            hold = (id, top, width, heights)
            holdPinnedUntil = ProcessInfo.processInfo.systemUptime + 0.4
        }
    }

    private var heights: [String: CGFloat] {
        Dictionary(rows.compactMap { row in docFrames[row.id].map { (row.id, $0.height) } }, uniquingKeysWith: { a, _ in a })
    }

    private func scheduleHold() {
        if !holdScheduled {
            holdScheduled = true
            DispatchQueue.main.async { [self] in
                holdScheduled = false
                applyHold()
            }
        }
    }

    private func applyHold() {
        if let hold, let scrollView, let now = docFrames[hold.id] {
            let sameWidth = scrollView.contentView.bounds.width == hold.width
            let heights = self.heights
            if sameWidth, ProcessInfo.processInfo.systemUptime >= keepingUntil,
               let delta = PresentHold.correction(heldTop: hold.top, nowTop: now.minY),
               PresentHold.mayCorrect(recent: holdCorrections, now: ProcessInfo.processInfo.systemUptime) {
                holdCorrections = PresentHold.recording(ProcessInfo.processInfo.systemUptime, in: holdCorrections)
                InputTrailRecorder.shared.noteFocusScroll()

                holdPinnedUntil = ProcessInfo.processInfo.systemUptime + 0.4
                Self.scroll(scrollView, by: delta)
                let names = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                DiagnosticsStore.shared.note(
                    "present.hold",
                    detail: "kept \"\(names[hold.id] ?? "-")\" in place (scrolled \(Int(delta)) pt); "
                        + PresentHold.changes(before: hold.heights, after: heights, names: names))
            }
            self.hold = (hold.id, now.minY, scrollView.contentView.bounds.width, heights)
        }
    }

    private var docGrids: [String: PresentLanding.Grid] = [:]

    func noteDocGrid(_ grid: PresentLanding.Grid) {
        if docGrids[grid.id] != grid { docGrids[grid.id] = grid }
    }

    /// Scrolls the live slide into the middle of the page (`centers`), or
    /// only as far as needed, and then far enough that the slide after it
    /// shows too.
    func reveal(_ id: String, slide: Int, headerHeight: CGFloat, cause: String = "keyboard", centers: Bool = true) {
        let insets = scrollView?.contentInsets ?? NSEdgeInsets()
        guard let grid = docGrids[id], let scrollView else { return }
        let offset = Self.offsetFromTop(scrollView) + insets.top
        let viewport = scrollView.contentView.bounds.height - insets.top - insets.bottom
        let liveTop = PresentLanding.rowTop(slide: slide, in: grid) - offset
        var delta: CGFloat = 0
        if centers, let centring = PresentLanding.reveal(
            rowTop: liveTop, rowPitch: grid.rowPitch, viewport: viewport, topInset: headerHeight) {
            delta = centring
        }
        if slide + 1 < grid.count, let more = PresentLanding.revealNext(
            liveRowTop: liveTop - delta,
            nextRowTop: PresentLanding.rowTop(slide: slide + 1, in: grid) - offset - delta,
            rowPitch: grid.rowPitch, viewport: viewport, topInset: headerHeight) {
            delta += more
        }
        if abs(delta) >= 0.5 {
            InputTrailRecorder.shared.noteFocusScroll()
            Self.scroll(scrollView, by: delta)
            let name = rows.first { $0.id == id }?.name ?? "-"
            DiagnosticsStore.shared.note(
                "present.follow", detail: "\(cause): showed \"\(name)\" slide \(slide + 1) (scrolled \(Int(delta)) pt, top inset \(Int(insets.top)))")
        }
    }

    static func offsetFromTop(_ scrollView: NSScrollView?) -> CGFloat {
        if let clip = scrollView?.contentView, let document = scrollView?.documentView {
            document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY
        } else {
            0
        }
    }

    func show(_ items: [ServiceItem]) {
        if rows.map(\.id) != items.map(\.id) {
            rows = items.map { ($0.id, $0.name) }
        }
        let headers = Set(items.filter { $0.itemKind == .header }.map(\.id))
        if headers != headerIDs { headerIDs = headers }
    }

    private var cards: [PresentLanding.Card] {
        rows.compactMap { row in
            frame(row.id).map { PresentLanding.Card(id: row.id, top: $0.minY, height: $0.height) }
        }
    }

    private var currentGrids: [PresentLanding.Grid] {
        rows.compactMap { row in
            docGrids[row.id].map {
                PresentLanding.Grid(
                    id: $0.id, top: $0.top + contentOrigin.y, rowPitch: $0.rowPitch, across: $0.across, count: $0.count)
            }
        }
    }

    func moved() {
        // While the operator scrolls, the plan list follows at once rather
        // than catching up when the page stops.
        let scrolling = InputTrailRecorder.shared
        if PresentFollowRule.operatorScrolled(
            sinceScroll: scrolling.sincePageScroll(), sinceFocus: scrolling.sinceFocusScroll()),
           let id = PresentLanding.itemAtLine(cards, line: readingLine, skipping: headerIDs) {
            onOperatorScroll?(id)
        }
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled, ProcessInfo.processInfo.systemUptime >= self.keepingUntil {
                self.anchor = PresentLanding.anchor(self.cards, grids: self.currentGrids)
            }
            let recorder = InputTrailRecorder.shared
            if !Task.isCancelled,
               PresentFollowRule.operatorScrolled(
                   sinceScroll: recorder.sincePageScroll(), sinceFocus: recorder.sinceFocusScroll()),
               let id = PresentLanding.itemAtLine(self.cards, line: self.readingLine, skipping: self.headerIDs) {
                self.onOperatorScroll?(id)
            }
        }
    }

    func keepPlace(because reason: String) {
        if let anchor {
            keepTask?.cancel()
            keepingUntil = ProcessInfo.processInfo.systemUptime + 0.8
            keepTask = Task { @MainActor in
                var moved: CGFloat = 0
                for wait in [0, 100, 250] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    if !Task.isCancelled,
                       let delta = PresentLanding.correction(for: anchor, in: self.cards, grids: self.currentGrids),
                       abs(delta) >= 1, let scrollView = self.scrollView {
                        InputTrailRecorder.shared.noteFocusScroll()
                        self.holdPinnedUntil = ProcessInfo.processInfo.systemUptime + 0.4
                        Self.scroll(scrollView, by: delta)
                        moved += delta
                    }
                }
                if moved != 0 {
                    let name = self.rows.first { $0.id == anchor.id }?.name ?? "-"
                    DiagnosticsStore.shared.note(
                        "present.anchor",
                        detail: "\(reason): kept \"\(name)\" "
                            + (anchor.slide.map { "slide \($0 + 1)" } ?? "at \(Int(anchor.fraction * 100))%")
                            + " at the top (scrolled \(Int(moved)) pt)")
                }
            }
        }
    }

    private static func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        let clip = scrollView.contentView
        let height = scrollView.documentView?.frame.height ?? 0
        let flipped = scrollView.documentView?.isFlipped ?? true
        let target = flipped ? clip.bounds.minY + delta : clip.bounds.minY - delta
        let clamped = min(max(target, 0), max(height - clip.bounds.height, 0))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    func reportLanding(target: String, rows: [ServiceItem]) {
        let name = { (id: String?) in id.flatMap { id in rows.first { $0.id == id }?.name } ?? "-" }
        Task { @MainActor in
            for (label, wait) in [("0.4 s", 0.4), ("2 s", 1.6)] {
                try? await Task.sleep(for: .seconds(wait))
                let cards = rows.compactMap { row in
                    self.frame(row.id).map { PresentLanding.Card(id: row.id, top: $0.minY, height: $0.height) }
                }
                let atTop = PresentLanding.cardAtTop(cards)
                let wanted = cards.first { $0.id == target }.map { "\(Int($0.top))" } ?? "?"
                DiagnosticsStore.shared.note(
                    "present.focus.landed",
                    detail: "\(label) after: wanted \(target) \"\(name(target))\" (its top at \(wanted) pt);"
                        + " at the top: \(atTop?.id ?? "-") \"\(name(atTop?.id))\"")
            }
        }
    }
}


/// Whether the operator is scrolling the plan page: from the first wheel
/// event over it until `rest` after the last (momentum included). While it
/// is, the page's content answers no hit-tests (PageScrollHitGate). On the
/// booth a fast scroll's main thread was 40% hit-testing: AppKit and SwiftUI
/// asked, several times a frame, what was under the still pointer as the
/// page moved under it (to route each wheel event, for hover and for the
/// cursor), and each built tile, with its hover and its drag source (an
/// AppKit view of its own), answered. Nothing on the page needs the pointer
/// while it scrolls; a click ends it at once.
@MainActor @Observable final class PageScrolling {
    static let shared = PageScrolling()

    private(set) var active = false
    @ObservationIgnored private var lastWheel: TimeInterval = 0
    @ObservationIgnored private var checking = false
    static let rest: TimeInterval = 0.12

    func wheel() {
        lastWheel = ProcessInfo.processInfo.systemUptime
        if !active { active = true }
        check()
    }

    func pointerDown() {
        if active { active = false }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rest) { [self] in
            checking = false
            guard active else { return }
            if ProcessInfo.processInfo.systemUptime - lastWheel >= Self.rest {
                active = false
            } else {
                check()
            }
        }
    }
}
