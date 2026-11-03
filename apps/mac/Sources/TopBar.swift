import AppKit
import RenderEngine
import SwiftUI

// MARK: Sizes

/// The bar across the top of the main window, laid out like ProPresenter's:
/// a round Search button, then rounded groups of buttons with a small label
/// under each icon, and the screens' status at the right. Every size is
/// fixed here, so what fits at a width is decided by arithmetic, not by
/// trying layouts.
enum TopBarMetrics {
    /// As tall as the window's (empty) toolbar, so the traffic lights sit
    /// centred on it.
    static let height: CGFloat = 52
    static let groupHeight: CGFloat = 40
    static let cellHeight: CGFloat = 34
    static let cellMinWidth: CGFloat = 40
    static let groupPadding: CGFloat = 3
    static let groupGap: CGFloat = 8
    /// Room at the left for the close, minimise and zoom buttons.
    static let trafficLights: CGFloat = 88
    static let trailing: CGFloat = 12
    /// The Search button is a circle as tall as a group.
    static let searchSize: CGFloat = groupHeight
    static let iconSize: CGFloat = 14.5
    static let labelSize: CGFloat = 9.5

    /// The bar's own surface: a step up from the window's near-black
    /// backdrop, so it reads as chrome, with a hairline under it.
    static let surface = Color(red: 0.082, green: 0.086, blue: 0.098)
    static let groupFill = Color.white.opacity(0.065)
    static let groupStroke = Color.white.opacity(0.08)
}

/// What fits at the window's width. Full shows every button on its own;
/// compact folds the slide builders into one Add menu and the planning
/// buttons into More; tight also moves Stage into More, which already has
/// Edit Stage Display. The widths are the full row's sum with a margin, so
/// a resize never makes the bar flip back and forth or overlap.
enum TopBarFit: Equatable {
    case full, compact, tight

    static func at(_ width: CGFloat) -> TopBarFit {
        if width >= 1320 { return .full }
        if width >= 1080 { return .compact }
        return .tight
    }
}

// MARK: Cells

/// One button's face: the icon, and its label under it. A selected cell
/// (the mode that's on) gets a lighter plate; `plate` colours one that is
/// doing something, like Listen while the microphone is open.
struct TopBarCellLabel<Icon: View>: View {
    let title: String
    var selected = false
    var tint: Color? = nil
    var plate: Color? = nil
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 2) {
            icon
                .font(.system(size: TopBarMetrics.iconSize, weight: .regular))
                .frame(height: 17)
                .foregroundStyle(tint ?? (selected ? Color.primary : Color.primary.opacity(0.82)))
            Text(title)
                .font(.system(size: TopBarMetrics.labelSize, weight: .medium))
                .foregroundStyle(tint ?? (selected ? Color.primary : Color.secondary))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(minWidth: TopBarMetrics.cellMinWidth)
        .frame(height: TopBarMetrics.cellHeight)
        .background {
            if let plate {
                Capsule().fill(plate)
            } else if selected {
                Capsule().fill(Color.white.opacity(0.14))
            }
        }
        .contentShape(Capsule())
    }
}

extension TopBarCellLabel where Icon == Image {
    init(_ title: String, systemImage: String, selected: Bool = false, tint: Color? = nil, plate: Color? = nil) {
        self.init(title: title, selected: selected, tint: tint, plate: plate) { Image(systemName: systemImage) }
    }
}

/// A bar button: a faint plate on hover and a firmer one while pressed.
struct TopBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TopBarButtonBody(configuration: configuration)
    }
}

private struct TopBarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .background {
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.07 : 0))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Menus draw their label themselves (a custom button style doesn't reach
/// them), so the hover plate goes on from outside.
struct TopBarMenuHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(Color.white.opacity(hovering ? 0.07 : 0))
                    .frame(height: TopBarMetrics.cellHeight)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// A Menu in the bar, drawn as one of its cells.
    func topBarMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(TopBarMenuHover())
    }
}

/// A rounded capsule holding a run of cells, like ProPresenter's groups.
struct TopBarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(TopBarMetrics.groupPadding)
            .frame(height: TopBarMetrics.groupHeight)
            .background(Capsule().fill(TopBarMetrics.groupFill))
            .overlay(Capsule().strokeBorder(TopBarMetrics.groupStroke, lineWidth: 0.5))
            .fixedSize()
    }
}

// MARK: Screens' status

/// Whether a screen is going out: green while it sends, amber while it is
/// starting or has a fault, grey while nothing carries it.
@MainActor
enum ScreenSignal {
    case sending, trouble, off

    var color: Color {
        switch self {
        case .sending: Color(red: 0.24, green: 0.86, blue: 0.42)
        case .trouble: HopeStyle.amber
        case .off: Color.white.opacity(0.22)
        }
    }

    /// From the same places Settings › Screens reads: the screen's output
    /// (a display, a DeckLink port or NDI) and that output's state.
    static func of(_ role: ShowScreen, render: RenderContext?) -> (signal: ScreenSignal, detail: String) {
        guard let render, let output = ScreenOutput(role, render: render) else { return (.off, "Not set up") }
        if output.current == "none" { return (.off, "No output chosen") }
        if output.isProblem { return (.trouble, output.status ?? "Not sending") }
        if output.deckLinkBacking != nil {
            if case .sending? = DeckLinkScreenOutputs.shared.status(for: output.screen.id) {
                return (.sending, output.status ?? "Sending")
            }
            return (.trouble, output.status ?? "Not sending yet")
        }
        if output.ndiOn {
            if case .sending? = NDIScreenOutputs.shared.status(for: output.screen.id) {
                return (.sending, output.status ?? "Sending over NDI")
            }
            return (.trouble, output.status ?? "Not sending yet")
        }
        return (.sending, "On a display")
    }
}

/// A screen's dot with its name under it. A click opens Settings › Screens.
struct ScreenStatusCell: View {
    let role: ShowScreen
    let render: RenderContext?

    var body: some View {
        let state = ScreenSignal.of(role, render: render)
        Button { SettingsRouter.shared.open(.screens) } label: {
            TopBarCellLabel(title: role.name) {
                Circle()
                    .fill(state.signal.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: state.signal == .sending ? state.signal.color.opacity(0.7) : .clear, radius: 3)
            }
        }
        .buttonStyle(TopBarButtonStyle())
        .help("\(role.name): \(state.detail). Click for Settings › Screens.")
        .accessibilityLabel("\(role.name), \(state.detail)")
    }
}

// MARK: Listening

/// Starts and stops sermon listening; a red plate while it's on.
struct TopBarListenCell: View {
    @Bindable private var assist = LiveAssist.shared
    @AppStorage("show.controlsTab") private var tab: ShowControlsPanel.Tab = .timers

    private var on: Bool { assist.listening && assist.mode == .sermon }

    var body: some View {
        Button {
            if on {
                assist.stop()
            } else {
                tab = .sermon
                Task { await assist.startSermon() }
            }
        } label: {
            TopBarCellLabel("Listen", systemImage: on ? "mic.fill" : "mic",
                            tint: on ? .white : nil, plate: on ? HopeStyle.live : nil)
        }
        .buttonStyle(TopBarButtonStyle())
        .help(on ? "Stop listening to the sermon" : "Listen to the sermon: transcribe it and catch every Bible reference")
    }
}

// MARK: Window

/// The main window keeps an empty toolbar so its title bar is toolbar
/// height with the traffic lights centred, draws no title or backing of its
/// own, and lets the top bar (drawn by the content, under it) take the
/// clicks. Put back as it was when the workspace goes, so Simple Mode's own
/// toolbar and title show normally.
struct TopBarWindowChrome: NSViewRepresentable {
    static let toolbarID = NSToolbar.Identifier("screens-top-bar")

    final class ChromeView: NSView {
        private weak var configured: NSWindow?
        private var toolbarWatch: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }

        func configure(_ window: NSWindow) {
            configured = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            installToolbar(window)
            // SwiftUI may take its toolbar away when its own items change
            // (the split view's, between modes); without one the title bar
            // shrinks and the traffic lights jump up off the bar's centre.
            toolbarWatch = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard window.toolbar == nil, self?.configured === window else { return }
                    DispatchQueue.main.async { self?.installToolbar(window) }
                }
            }
        }

        private func installToolbar(_ window: NSWindow) {
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: TopBarWindowChrome.toolbarID)
            }
            window.toolbarStyle = .unified
        }

        func restore() {
            toolbarWatch?.invalidate()
            toolbarWatch = nil
            guard let window = configured else { return }
            configured = nil
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            if window.toolbar?.identifier == TopBarWindowChrome.toolbarID { window.toolbar = nil }
        }
    }

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {}
    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) { nsView.restore() }
}

/// The bar's empty space moves the window, and a double-click does what
/// System Settings › Desktop & Dock says a title bar double-click does.
struct TopBarDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: The bar

/// A panel's pin in the bar: Plan at the left, Screens at the right.
struct TopBarToggle {
    let title: String
    let systemImage: String
    let on: Bool
    let help: String
    let action: () -> Void
}

/// What the bar's buttons do; the window that owns the sheets supplies them.
struct TopBarActions {
    var songs: () -> Void
    var scripture: () -> Void
    var points: () -> Void
    var sermon: () -> Void
    var media: () -> Void
    var scheduleService: (() -> Void)?
    var assistant: () -> Void
    var editStage: () -> Void
}

struct TopBar<Themes: View, ScriptureMenu: View, More: View>: View {
    @AppStorage(MediaDrawer.openKey) private var mediaBinOpen = false
    let fit: TopBarFit
    /// The window's title bar height, so the bar is centred on the traffic lights.
    let height: CGFloat
    @Binding var modeRaw: String
    let render: RenderContext?
    let controls: ServiceControls?
    let searchOpen: Bool
    let namespace: Namespace.ID
    let onSearch: () -> Void
    let plan: TopBarToggle?
    let screens: TopBarToggle?
    let actions: TopBarActions
    @ViewBuilder let themes: () -> Themes
    @ViewBuilder let scriptureMenu: () -> ScriptureMenu
    @ViewBuilder let more: () -> More

    private var mode: AppMode { AppMode(rawValue: modeRaw) ?? .present }

    var body: some View {
        HStack(spacing: TopBarMetrics.groupGap) {
            Color.clear.frame(width: TopBarMetrics.trafficLights - TopBarMetrics.groupGap, height: 1)
            TopBarSearchButton(open: searchOpen, namespace: namespace, action: onSearch)
            if let plan { TopBarGroup { toggleCell(plan) } }
            modes
            builders
            Spacer(minLength: 12)
            TopBarGroup { mediaCell }
            if let controls {
                TopBarGroup {
                    TransitionChip(
                        glyph: .presentations,
                        kindKey: SlideTransitionDefault.kindKey, durationKey: SlideTransitionDefault.durationKey,
                        fallbackKind: SlideTransitionDefault.kind.rawValue, fallbackDuration: SlideTransitionDefault.duration,
                        showSlider: false, showsName: true, inTopBar: true)
                }
                TopBarGroup {
                    if fit != .tight { stageCell }
                    TopBarListenCell()
                }
                if fit == .full {
                    TopBarGroup {
                        scheduleCell
                        assistantCell
                        moreCell
                    }
                } else {
                    TopBarGroup { moreCell }
                }
                TopBarGroup { ClearChip(controls: controls, inTopBar: true) }
            } else {
                TopBarGroup { moreCell }
            }
            TopBarGroup {
                ForEach(ShowScreen.allCases) { ScreenStatusCell(role: $0, render: render) }
            }
            if let screens { TopBarGroup { toggleCell(screens) } }
        }
        .padding(.trailing, TopBarMetrics.trailing)
        .frame(height: height)
        // Exactly the window's width whatever the row needs (the width
        // measured from it decides the fit), and a row wider than that
        // runs off the right edge rather than back under the traffic lights.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(TopBarDragArea())
        .background {
            TopBarMetrics.surface
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
        }
    }

    // MARK: Groups

    private var modes: some View {
        TopBarGroup {
            modeCell(.present, title: "Present", symbol: "play.rectangle", help: "Present (⌘1)")
            modeCell(.edit, title: "Edit", symbol: "pencil", help: "Edit (⌘2)")
            modeCell(.scheduler, title: "Schedule", symbol: "calendar", help: "Schedule (⌘3)")
        }
    }

    @ViewBuilder
    private var builders: some View {
        if fit == .full {
            TopBarGroup {
                Button(action: actions.songs) { TopBarCellLabel("Songs", systemImage: "music.note") }
                    .buttonStyle(TopBarButtonStyle())
                    .help("Song Search: import a song and arrangement from Shepherd (⌘⇧L)")
                Button(action: actions.scripture) { TopBarCellLabel("Scripture", systemImage: "book") }
                    .buttonStyle(TopBarButtonStyle())
                    .contextMenu { scriptureMenu() }
                    .help("Add scripture slides (⌘⇧B). Right-click for listening and the Bible theme.")
                Button(action: actions.points) { TopBarCellLabel("Points", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(TopBarButtonStyle())
                    .help("Add sermon point slides (⌘⇧P)")
                Button(action: actions.sermon) { TopBarCellLabel("Sermon", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(TopBarButtonStyle())
                    .help("Import the week's sermon notes (⌘⇧I)")
                Menu { themes() } label: { TopBarCellLabel("Theme", systemImage: "paintpalette") }
                    .topBarMenu()
                    .help("Open a theme in the theme editor")
            }
        } else {
            // Narrow windows: the builders share one menu.
            TopBarGroup {
                Menu {
                    Button("Song Search…", action: actions.songs)
                    Button("Scripture…", action: actions.scripture)
                    Button("Point Slides…", action: actions.points)
                    Button("Import Sermon…", action: actions.sermon)
                    Divider()
                    Menu("Themes") { themes() }
                } label: {
                    TopBarCellLabel("Add", systemImage: "plus.rectangle.on.rectangle")
                }
                .topBarMenu()
                .help("Songs, scripture, sermon points, sermon notes and themes")
            }
        }
    }

    // MARK: Cells

    private func modeCell(_ cellMode: AppMode, title: String, symbol: String, help: String) -> some View {
        Button { modeRaw = cellMode.rawValue } label: {
            TopBarCellLabel(title, systemImage: symbol, selected: mode == cellMode)
        }
        .buttonStyle(TopBarButtonStyle())
        .help(help)
    }

    private func toggleCell(_ toggle: TopBarToggle) -> some View {
        Button(action: toggle.action) {
            TopBarCellLabel(toggle.title, systemImage: toggle.systemImage, selected: toggle.on)
        }
        .buttonStyle(TopBarButtonStyle())
        .help(toggle.help)
    }

    private var mediaCell: some View {
        Button(action: actions.media) {
            TopBarCellLabel("Media", systemImage: "photo.on.rectangle", selected: mediaBinOpen)
        }
        .buttonStyle(TopBarButtonStyle())
        .help(mediaBinOpen ? "Fold the media bin away" : "The media bin, under the plan: drag a background onto a slide, a song or the plan")
    }

    private var stageCell: some View {
        Button(action: actions.editStage) {
            TopBarCellLabel("Stage", systemImage: "rectangle.inset.filled.and.person.filled")
        }
        .buttonStyle(TopBarButtonStyle())
        .help("Edit the stage display")
    }

    private var scheduleCell: some View {
        Button { actions.scheduleService?() } label: {
            TopBarCellLabel("Start Time", systemImage: "calendar.badge.clock")
        }
        .buttonStyle(TopBarButtonStyle())
        .disabled(actions.scheduleService == nil)
        .help("When this service starts and when its countdown starts")
    }

    private var assistantCell: some View {
        Button(action: actions.assistant) { TopBarCellLabel("Assistant", systemImage: "sparkles") }
            .buttonStyle(TopBarButtonStyle())
            .help("Assistant (⇧⌘A)")
    }

    private var moreCell: some View {
        Menu { more() } label: { TopBarCellLabel("More", systemImage: "ellipsis.circle") }
            .topBarMenu()
            .help("Message & Series, Pre-Service Slides, Themes, Simple Mode, Timers & Macros, Screen Setup")
    }
}
