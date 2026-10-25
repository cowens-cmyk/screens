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
            if place == Self.page { lastPageScroll = now }
            what = "scroll in \(place)"
        case .rightMouseDown:
            what = "right-click in \(region(at: event.locationInWindow, in: event.window))"
        case .otherMouseDown:
            what = "other-click in \(region(at: event.locationInWindow, in: event.window))"
        default:
            let click = event.clickCount > 1 ? "double-click" : "click"
            let place = region(at: event.locationInWindow, in: event.window)
            if place == Self.page { lastPageClick = now }
            what = "\(click) in \(place)"
        }

        trail.record(what, at: now)
    }

    /// The whole-plan page's region name (ServiceContinuousView).
    private static let page = "present"

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
    private(set) var frames: [String: CGRect] = [:]

    private var grids: [String: PresentLanding.Grid] = [:]

    weak var scrollView: NSScrollView?

    private var rows: [(id: String, name: String)] = []

    /// Plan headers: bands on the page, never the item it is showing.
    private var headerIDs: Set<String> = []

    /// Told the item at the top once the page stops where the operator
    /// scrolled it, so the plan list can highlight it.
    var onOperatorScroll: ((String) -> Void)?

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

    func note(_ id: String, _ frame: CGRect) {
        if frames[id] != frame { frames[id] = frame }
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

    func noteGrid(_ grid: PresentLanding.Grid) {
        if grids[grid.id] != grid { grids[grid.id] = grid }
    }

    private var docGrids: [String: PresentLanding.Grid] = [:]

    func noteDocGrid(_ grid: PresentLanding.Grid) {
        if docGrids[grid.id] != grid { docGrids[grid.id] = grid }
    }

    func reveal(_ id: String, slide: Int, headerHeight: CGFloat, cause: String = "keyboard") {
        let insets = scrollView?.contentInsets ?? NSEdgeInsets()
        if let grid = docGrids[id], let scrollView,
           let delta = PresentLanding.reveal(
               rowTop: PresentLanding.rowTop(slide: slide, in: grid) - Self.offsetFromTop(scrollView) - insets.top,
               rowPitch: grid.rowPitch,
               viewport: scrollView.contentView.bounds.height - insets.top - insets.bottom,
               topInset: headerHeight) {
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
            frames[row.id].map { PresentLanding.Card(id: row.id, top: $0.minY, height: $0.height) }
        }
    }

    private var currentGrids: [PresentLanding.Grid] {
        rows.compactMap { grids[$0.id] }
    }

    func moved() {
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
               let id = PresentLanding.itemAtTop(self.cards, skipping: self.headerIDs) {
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
                    self.frames[row.id].map { PresentLanding.Card(id: row.id, top: $0.minY, height: $0.height) }
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
