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

        public var duration: Duration {
            switch self {
            case .open: ShellPanel.openDelay
            case .close: ShellPanel.graceDelay
            }
        }
    }

    public static let openDelay: Duration = .milliseconds(150)
    public static let graceDelay: Duration = .milliseconds(350)
    /// After a click folds a pinned panel away, the bubble lands where the
    /// pointer already is; hovering doesn't reopen it for this long.
    public static let quietAfterCollapse: TimeInterval = 0.6

    public private(set) var mode: Mode
    /// Whether the pointer is over the bubble or the peeking panel.
    public private(set) var hovering = false
    /// Bumped by every event, so a wait asked for before it is stale.
    public private(set) var generation = 0
    private var quietUntil: TimeInterval = 0

    public init(pinned: Bool) {
        mode = pinned ? .pinned : .collapsed
    }

    /// Docked beside the slides: the one state that's remembered.
    public var isPinned: Bool { mode == .pinned }
    /// Floating over the slides.
    public var isPeeking: Bool { mode == .peek }

    public mutating func pointerEntered(at now: TimeInterval) -> Wait? {
        hovering = true
        generation += 1
        guard mode == .collapsed, now >= quietUntil else { return nil }
        return .open(generation: generation)
    }

    public mutating func pointerLeft() -> Wait? {
        hovering = false
        generation += 1
        guard mode == .peek else { return nil }
        return .close(generation: generation)
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
            return nil
        }
    }

    /// The bubble, the strip or the pin button: pins a collapsed or peeking
    /// panel, and collapses a pinned one.
    public mutating func click(at now: TimeInterval) {
        generation += 1
        switch mode {
        case .collapsed, .peek:
            mode = .pinned
        case .pinned:
            mode = .collapsed
            quietUntil = now + Self.quietAfterCollapse
        }
    }

    /// The View menu or its shortcut. The pointer is nowhere near the
    /// bubble, so no quiet period.
    public mutating func toggle() {
        generation += 1
        mode = mode == .pinned ? .collapsed : .pinned
    }

    /// A pinned state set from outside (another window changed the stored
    /// preference). A peek stays a peek unless it's being pinned.
    public mutating func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        generation += 1
        mode = pinned ? .pinned : .collapsed
    }

    /// The panel stops being shown (Edit mode, or the window's content
    /// changed): a peek folds away without waiting.
    public mutating func dismissPeek() {
        guard mode == .peek else { return }
        generation += 1
        hovering = false
        mode = .collapsed
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
