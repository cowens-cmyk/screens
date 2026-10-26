import Foundation

/// The main window's side panels (the plan on the left, the screens on the
/// right) each sit in one of three states. Collapsed, the panel is a small
/// bubble or strip over the slides; hovering it opens a peek, a floating
/// copy of the panel that leaves the slides where they are and folds away
/// again once the pointer has been gone a moment; a click pins it as a
/// docked column beside the slides.
///
/// The decisions live here, free of SwiftUI, so the timing rules can be
/// tested. The view feeds in pointer events and clicks; when a call returns
/// a `Wait`, the view sleeps that long and hands it back to `waited(_:)`.
/// A wait is only honoured if nothing has happened since it was asked for,
/// so a pointer that comes back during the grace period simply keeps the
/// peek open.
///
/// The open panel's content (the plan's lists, the screens' previews) is
/// heavy to build, and building it in the frame the shape starts to grow is
/// what made the motion stutter. So it's built while the pointer waits out
/// the open delay, before anything moves, and kept until the shape has
/// folded and settled; only then is it let go, when nothing is moving.
public struct ShellPanel: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case collapsed, peek, pinned
    }

    /// A timer the view should run, and give back when it's done.
    public enum Wait: Equatable, Sendable {
        /// Before a hover opens the peek, so a pointer crossing the bubble
        /// on its way to the toolbar doesn't flash the panel open, and a
        /// quick click on the bubble lands on the bubble.
        case open(generation: Int)
        /// After the pointer leaves a peek, so a diagonal move that clips
        /// the panel's edge doesn't fold it shut.
        case close(generation: Int)
        /// After the panel has folded and its shape has settled: the open
        /// content, kept while the shape shrank over it, can go.
        case release(generation: Int)

        public var duration: Duration {
            switch self {
            case .open: ShellPanel.openDelay
            case .close: ShellPanel.graceDelay
            case .release: .milliseconds(Int((ShellPanel.settleTime * 1000).rounded(.up)))
            }
        }
    }

    public static let openDelay: Duration = .milliseconds(150)
    public static let graceDelay: Duration = .milliseconds(350)
    /// After a click folds a pinned panel away, the bubble lands where the
    /// pointer already is; hovering doesn't reopen it for this long.
    public static let quietAfterCollapse: TimeInterval = 0.6

    /// The spring the panels open and fold with: quick, with a little
    /// overshoot, like the iPhone's Dynamic Island.
    public static let springResponse: Double = 0.42
    public static let springDamping: Double = 0.72
    /// How long the shape keeps moving after a change: until the spring's
    /// swing has died down to half a percent of the distance travelled.
    public static var settleTime: TimeInterval {
        log(200) * springResponse / (2 * .pi * springDamping)
    }

    public private(set) var mode: Mode
    /// Whether the pointer is over the bubble or the peeking panel.
    public private(set) var hovering = false
    /// Bumped by every event, so a wait asked for before it is stale.
    public private(set) var generation = 0
    /// Whether the open panel's content should exist: from the moment the
    /// pointer reaches the bubble (or a pin is asked for) until the folded
    /// shape has settled. Hidden while folded, so nothing in it is drawn.
    public private(set) var contentBuilt: Bool
    private var quietUntil: TimeInterval = 0

    public init(pinned: Bool) {
        mode = pinned ? .pinned : .collapsed
        contentBuilt = pinned
    }

    /// Docked beside the slides: the one state that's remembered.
    public var isPinned: Bool { mode == .pinned }
    /// Floating over the slides.
    public var isPeeking: Bool { mode == .peek }

    /// Which of the panel's two faces is showing, and so which one's live
    /// previews should draw: the strip's while folded, the column's while
    /// peeking or pinned. The other face is hidden and its previews paused.
    public var showsOpenFace: Bool { mode != .collapsed }

    public mutating func pointerEntered(at now: TimeInterval) -> Wait? {
        hovering = true
        generation += 1
        // Built now, during the open delay, so the frame the shape starts
        // to grow in has nothing to build.
        contentBuilt = true
        guard mode == .collapsed, now >= quietUntil else { return nil }
        return .open(generation: generation)
    }

    public mutating func pointerLeft() -> Wait? {
        hovering = false
        generation += 1
        switch mode {
        case .peek: return .close(generation: generation)
        case .collapsed: return contentBuilt ? .release(generation: generation) : nil
        case .pinned: return nil
        }
    }

    /// A wait has run its time. `holding` is true while something opened
    /// from the panel still needs it (a menu, a popover, a drag, a field
    /// being typed in): the peek stays and the grace period starts over.
    public mutating func waited(_ wait: Wait, holding: Bool = false) -> Wait? {
        switch wait {
        case .open(let asked):
            guard asked == generation, mode == .collapsed, hovering else { return nil }
            mode = .peek
            return nil
        case .close(let asked):
            guard asked == generation, mode == .peek, !hovering else { return nil }
            if holding {
                generation += 1
                return .close(generation: generation)
            }
            mode = .collapsed
            return .release(generation: generation)
        case .release(let asked):
            guard asked == generation, mode == .collapsed, !hovering else { return nil }
            contentBuilt = false
            return nil
        }
    }

    /// The bubble, the strip or the pin button: pins a collapsed or peeking
    /// panel, and collapses a pinned one. A fold gives back the wait after
    /// which its content can go.
    @discardableResult
    public mutating func click(at now: TimeInterval) -> Wait? {
        generation += 1
        switch mode {
        case .collapsed, .peek:
            mode = .pinned
            contentBuilt = true
            return nil
        case .pinned:
            mode = .collapsed
            quietUntil = now + Self.quietAfterCollapse
            return .release(generation: generation)
        }
    }

    /// The View menu or its shortcut. The pointer is nowhere near the
    /// bubble, so no quiet period.
    @discardableResult
    public mutating func toggle() -> Wait? {
        setMode(mode == .pinned ? .collapsed : .pinned)
    }

    /// A pinned state set from outside (another window changed the stored
    /// preference). A peek stays a peek unless it's being pinned.
    @discardableResult
    public mutating func setPinned(_ pinned: Bool) -> Wait? {
        guard pinned != isPinned else { return nil }
        return setMode(pinned ? .pinned : .collapsed)
    }

    /// A pin asked for with nothing built yet (the menu, its shortcut): the
    /// view builds the content first and grows the shape a frame later, so
    /// the two don't land in the same frame.
    public var needsContentBeforePin: Bool { !contentBuilt && mode != .pinned }

    public mutating func buildContent() {
        contentBuilt = true
    }

    private mutating func setMode(_ new: Mode) -> Wait? {
        generation += 1
        mode = new
        if new == .collapsed { return .release(generation: generation) }
        contentBuilt = true
        return nil
    }

    /// The panel stops being shown (Edit mode, or the window's content
    /// changed): a peek folds away without waiting. Its views go with it,
    /// so there's nothing left to release.
    public mutating func dismissPeek() {
        guard mode == .peek else { return }
        generation += 1
        hovering = false
        mode = .collapsed
        contentBuilt = false
    }
}

extension ShellPanel {
    /// Which panel, and where its pinned state is kept: per Mac, since it's
    /// about this window and this screen, not the library.
    public enum Side: String, CaseIterable, Sendable {
        case plans, screens

        public var defaultsKey: String { "shell.\(rawValue).pinned" }

        /// The plan starts docked, as the sidebar always was; the screens
        /// start as the strip, giving the slides the room.
        public var pinnedByDefault: Bool { self == .plans }

        public func storedPinned(in defaults: UserDefaults) -> Bool {
            defaults.object(forKey: defaultsKey) as? Bool ?? pinnedByDefault
        }
    }
}
