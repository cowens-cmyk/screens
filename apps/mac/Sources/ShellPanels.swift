import AppKit
import PresenterCore
import RenderEngine
import SwiftUI

// The main window's panels, around the slides: the plan bubble, the screens
// strip, the peeking cards they open into, the show's control bar and the
// backdrop behind it all. When the decisions are made is in PresenterCore's
// ShellPanel; this is the drawing and the AppKit plumbing.

/// Feeds a panel the pointer and runs the waits it asks for. On the one view
/// that is the bubble when collapsed and the card when peeking, so the
/// pointer is never "outside" while one becomes the other. Hover only ever
/// changes what shows: it never takes the keyboard and never fires anything.
struct ShellPanelHover: ViewModifier {
    @Binding var panel: ShellPanel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                let wait = inside
                    ? panel.pointerEntered(at: ProcessInfo.processInfo.systemUptime)
                    : panel.pointerLeft()
                run(wait)
            }
            .onChange(of: panel.mode) { old, new in
                if new == .peek { PanelFocus.remember() }
                if old == .peek { PanelFocus.restoreIfOrphaned() }
            }
            .onAppear { PanelHold.watchMenus() }
    }

    private func run(_ wait: ShellPanel.Wait?) {
        guard let wait else { return }
        let binding = $panel
        let animation = HopeMotion.ui(reduced: reduceMotion)
        Task { @MainActor in
            try? await Task.sleep(for: wait.duration)
            let next = withAnimation(animation) {
                binding.wrappedValue.waited(wait, holding: PanelHold.isHolding)
            }
            run(next)
        }
    }
}

/// Whether something opened from a peeking panel still needs it: folding
/// the panel would take the menu, popover, sheet or drag down with it, or
/// cut off someone typing in its field.
@MainActor
enum PanelHold {
    private static var menusOpen = 0
    private static var watching = false

    static var isHolding: Bool {
        if NSEvent.pressedMouseButtons != 0 || menusOpen > 0 { return true }
        guard let window = NSApp.mainWindow else { return false }
        if window.attachedSheet != nil { return true }
        if window.firstResponder is NSText { return true }
        let popoverOpen = window.childWindows?.contains {
            $0.isVisible && String(describing: type(of: $0)).contains("Popover")
        } ?? false
        return popoverOpen
    }

    /// Menus (a row's context menu, the add menu) run their own event loop,
    /// so their open state comes from AppKit's notifications.
    static func watchMenus() {
        guard !watching else { return }
        watching = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { menusOpen += 1 }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { menusOpen = max(0, menusOpen - 1) }
        }
    }
}

/// A click in a peeking panel's list gives that list the keyboard; when the
/// panel folds away the keyboard would go with it, and the arrows and Space
/// would stop moving the slides. So the window's responder from before the
/// peek is put back, but only when the panel left nothing in charge: a peek
/// that was only looked at changes nothing.
@MainActor
enum PanelFocus {
    private static weak var saved: NSResponder?

    static func remember() {
        saved = NSApp.mainWindow?.firstResponder
    }

    static func restoreIfOrphaned() {
        // After SwiftUI has taken the panel's views out of the window.
        Task { @MainActor in
            guard let window = NSApp.mainWindow, let saved, saved !== window,
                  (saved as? NSView)?.window === window else { return }
            let current = window.firstResponder
            let orphaned = current == nil || current === window || (current as? NSView)?.window == nil
            if orphaned { window.makeFirstResponder(saved) }
        }
    }
}

// MARK: Sizes

enum ShellMetrics {
    /// The docked plan column and the peeking plan card.
    static let planWidth: CGFloat = 248
    /// The docked screens column and the peeking screens card: room for a
    /// 16:9 preview of about 240 by 135.
    static let screensWidth: CGFloat = 300
    static let bubbleHeight: CGFloat = 40
    static let thumbnail = CGSize(width: 72, height: 40)
    static let stripHeight: CGFloat = 62
    /// The gap between a floating piece and the edge of the slides.
    static let inset: CGFloat = 10
    /// Room kept clear at the top of the slides for the bubble and strip, so
    /// nothing sits under them when the page is scrolled to its top.
    static func band(planFloats: Bool, screensFloat: Bool) -> CGFloat {
        let tallest = max(planFloats ? bubbleHeight : 0, screensFloat ? stripHeight : 0)
        return tallest == 0 ? 0 : tallest + inset + 6
    }
}

extension View {
    /// A peeking panel: a floating card over the slides.
    func peekCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    /// A docked panel: translucent over the window's backdrop.
    func dockedPanel() -> some View {
        background(.ultraThinMaterial)
    }
}

// MARK: Plan bubble

/// The plan, folded: its name and the item the show is on, with the item's
/// kind. Also the header of the peeking and docked panels, where a click
/// pins or collapses it.
struct PlanBubbleLabel: View {
    let planName: String?
    let itemName: String?
    let kind: HopeStyle.ItemKind?
    var pinned = false
    var showsPin = true

    var body: some View {
        HStack(spacing: 8) {
            if let kind {
                Image(systemName: kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(kind.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(planName ?? "No Plan")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(itemName ?? (planName == nil ? "Choose a plan" : "No item selected"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if showsPin {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinned ? AnyShapeStyle(HopeStyle.blue) : AnyShapeStyle(.secondary))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: Screens strip

/// The screens, folded: a tiny live preview of each, at a third of the full
/// previews' frame rate, with a red edge while something's up on it.
struct ScreensStrip: View {
    let render: RenderContext
    let controls: ServiceControls?
    let screens: [MonitorsPanel.Entry]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(screens) { screen in
                VStack(spacing: 2) {
                    thumbnail(screen)
                        .frame(width: ShellMetrics.thumbnail.width, height: ShellMetrics.thumbnail.height)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isLive(screen) ? HopeStyle.live : .white.opacity(0.12),
                                              lineWidth: isLive(screen) ? 1.5 : 1))
                    Text(screen.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: ShellMetrics.thumbnail.width)
                }
            }
            if screens.isEmpty {
                Text("Screens")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ShellMetrics.stripHeight)
        .contentShape(Rectangle())
    }

    /// Ten frames a second is plenty to see what's up at this size, and
    /// keeps an idle window idle.
    private static let framesPerSecond: Float = 10

    @ViewBuilder
    private func thumbnail(_ screen: MonitorsPanel.Entry) -> some View {
        if let target = screen.target {
            Group {
                if screen.role == .stream {
                    ZStack {
                        Checkerboard()
                        TransparentScenePreview(
                            compositor: render.compositor,
                            provider: render.outputs.previewProvider(for: target),
                            maximumFramesPerSecond: Self.framesPerSecond)
                    }
                } else if screen.role == .stage {
                    LiveSceneView(render: render, screenTargetID: target, maximumFramesPerSecond: Self.framesPerSecond)
                        .modifier(PreviewedLayoutKeeper(target: target))
                } else {
                    LiveSceneView(render: render, screenTargetID: target, maximumFramesPerSecond: Self.framesPerSecond)
                }
            }
            // The strip is one button; the Metal views mustn't swallow its click.
            .allowsHitTesting(false)
        } else {
            Color.primary.opacity(0.06)
                .overlay(Image(systemName: "display").font(.system(size: 11)).foregroundStyle(.tertiary))
        }
    }

    private func isLive(_ screen: MonitorsPanel.Entry) -> Bool {
        guard screen.target != nil, let controls, controls.hasAnyClearableContent else { return false }
        return screen.role != .stream || ShowSetup.shared.streamMode != .off
    }
}

// MARK: Control bar

/// Always over the slides in Present and Schedule, whatever the panels are
/// doing: Clear All, the sermon time, and whether a microphone is open.
struct ShowControlBar: View {
    let controls: ServiceControls
    /// About as wide as it draws with the microphone showing; the bottom bar
    /// lays the slide size control out around it.
    static let width: CGFloat = 250
    @State private var clearTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = LiveAssist.shared.listening
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if listening {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(HopeStyle.live, in: Circle())
                            .help("Listening to a microphone")
                            .transition(.opacity)
                    }
                    VStack(alignment: .leading, spacing: -2) {
                        Text("SERMON")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        SermonTimeReadout(timer: controls.sermonTimer, size: 15)
                    }
                    .help("Sermon timer. Set it under the stage preview.")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassEffect(.regular, in: Capsule())

                Button {
                    clearTaps += 1
                    controls.clearAll()
                } label: {
                    Label("Clear All", systemImage: "xmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .symbolEffect(.bounce.down, options: .speed(1.4), value: reduceMotion ? 0 : clearTaps)
                        .padding(.horizontal, 4)
                        .frame(height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(nil)
                .keyboardShortcut(.escape, modifiers: [.shift])
                .help("Clear every screen (⇧Esc)")
            }
            .fixedSize()
        }
        .animation(HopeMotion.ui(reduced: reduceMotion), value: listening)
    }
}

// MARK: Backdrop

/// Behind everything in the window's content: near black, a soft steel-blue
/// light from the top right of centre and a plum one from the lower left,
/// falling back to black at the edges. Gradients, not an image, so it fits
/// any window, and drawn once: nothing in it moves. Kept below the slides'
/// brightness, so they, their text and the live outline still lead.
struct ShellBackdrop: View {
    private static let base = Color(red: 0.020, green: 0.022, blue: 0.030)
    private static let steel = Color(red: 0x3E / 255, green: 0x8F / 255, blue: 0xB0 / 255)
    private static let plum = Color(red: 0x7A / 255, green: 0x2A / 255, blue: 0x5C / 255)

    var body: some View {
        ZStack {
            Self.base
            EllipticalGradient(
                colors: [Self.steel.opacity(0.55), Self.steel.opacity(0.22), .clear],
                center: UnitPoint(x: 0.6, y: 0.0),
                startRadiusFraction: 0, endRadiusFraction: 0.72)
            EllipticalGradient(
                colors: [Self.plum.opacity(0.50), Self.plum.opacity(0.18), .clear],
                center: UnitPoint(x: 0.24, y: 0.66),
                startRadiusFraction: 0, endRadiusFraction: 0.62)
            // The edges and corners back to black.
            EllipticalGradient(
                colors: [.clear, .black.opacity(0.5)],
                center: .center,
                startRadiusFraction: 0.5, endRadiusFraction: 0.8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
