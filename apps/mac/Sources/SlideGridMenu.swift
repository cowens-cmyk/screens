import AppKit
import PresenterCore
import SwiftUI

/// One right-click menu for a whole slide grid.
///
/// Each tile used to carry its own `.contextMenu`, and SwiftUI made the
/// menu's machinery for every tile of every row it built: with the drop
/// target, half of what a tile cost (docs/ui-smoothness.md). A menu on the
/// grid is made once, but SwiftUI doesn't say where in the grid the click
/// was, so the click is watched for here: a right-click (or a Control-click)
/// over a tile names that tile to its grid before the event goes on to
/// SwiftUI, and the menu is built for it.
///
/// Two things keep the menu on the right slide:
/// - SwiftUI hears of a change a moment later, not as it's made. Asked for
///   the menu straight after the tile was named, it gave the menu it had
///   built the time before: 133 times in 200 in a probe, and never once
///   pending work was flushed first (`CATransaction.flush`). So it is.
/// - The menu has items only for half a second after the click that named
///   its tile, and the tile is forgotten at the next click of any kind. A
///   menu asked for without a click over a tile comes back empty, and an
///   empty menu doesn't open: never a menu for some other slide.
@MainActor
@Observable
final class SlideGridMenuPress {
    /// Changed by every click that names a tile or forgets one. The menu
    /// reads it, so each right-click builds the menu again: a checkmark set
    /// from the menu shows the next time it opens on the same tile.
    private var presses = 0
    @ObservationIgnored private var index: Int?
    @ObservationIgnored private var pressedAt: TimeInterval = 0

    /// How long after its click a menu can still be built.
    static let window: TimeInterval = 0.5

    func press(_ index: Int) {
        self.index = index
        pressedAt = ProcessInfo.processInfo.systemUptime
        presses += 1
    }

    func forget() {
        if index != nil {
            index = nil
            presses += 1
        }
    }

    /// The tile to build the menu for, read where the menu is built.
    func tile() -> Int? {
        _ = presses
        guard let index, ProcessInfo.processInfo.systemUptime - pressedAt < Self.window else { return nil }
        return index
    }
}

/// Where a slide grid is in its window, for the click watcher: a view that
/// draws nothing and takes no clicks, laid behind the grid, so a click's
/// place in the window becomes a place in the grid.
struct SlideGridAnchor: NSViewRepresentable {
    let press: SlideGridMenuPress
    /// Each tile's frame by index, in the grid's own space.
    let frames: () -> [Int: CGRect]

    func makeNSView(context: Context) -> SlideGridAnchorView {
        let view = SlideGridAnchorView()
        SlideGridClicks.shared.watch(view)
        return view
    }

    func updateNSView(_ view: SlideGridAnchorView, context: Context) {
        view.press = press
        view.frames = frames
    }
}

final class SlideGridAnchorView: NSView {
    var press: SlideGridMenuPress?
    var frames: (() -> [Int: CGRect])?

    /// Top-left origin, as the grid's own space is.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The tile under an event's place, when it is over this grid's part of
    /// the window that shows.
    func tile(under event: NSEvent) -> Int? {
        guard let window, window === event.window, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point), let frames else { return nil }
        return SlideDropPlacement.tile(at: point, among: frames())?.index
    }
}

/// Watches the app's clicks for the slide grids' menus.
@MainActor
final class SlideGridClicks {
    static let shared = SlideGridClicks()

    private let anchors = NSHashTable<SlideGridAnchorView>.weakObjects()
    private var monitor: Any?

    private init() {}

    /// The grids in the app's windows now.
    var grids: [SlideGridAnchorView] { anchors.allObjects }

    func watch(_ view: SlideGridAnchorView) {
        anchors.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.saw(event) }
            return event
        }
    }

    /// Whether a click opens a menu: the right button, or Control with the
    /// left.
    static func opensMenu(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    func saw(_ event: NSEvent) {
        let opensMenu = Self.opensMenu(event)
        var named = false
        for view in anchors.allObjects {
            guard let press = view.press else { continue }
            if opensMenu, !named, let index = view.tile(under: event) {
                press.press(index)
                named = true
            } else {
                press.forget()
            }
        }
        // So the menu SwiftUI is about to be asked for is this click's.
        if named { CATransaction.flush() }
    }
}
