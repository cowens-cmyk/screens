import AppKit
import AudioEngine
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

/// What fits at the window's width. Full shows every button; compact lets
/// the bar's Clear go (Clear All is also under the slides); tight also
/// lets the screens' lights go (the Screens panel shows the same). The
/// widths are the full row's sum with a margin, so a resize never makes
/// the bar flip back and forth or overlap.
enum TopBarFit: Equatable {
    case full, compact, tight

    static func at(_ width: CGFloat) -> TopBarFit {
        if width >= 1240 { return .full }
        if width >= 1110 { return .compact }
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

/// Sermon listening on and off with a click; the menu picks the input it
/// hears, which LiveAssist saves, so the next service starts on the same
/// microphone. A red plate while it's on.
struct TopBarListenCell: View {
    @Bindable private var assist = LiveAssist.shared
    @AppStorage("show.controlsTab") private var tab: ShowControlsPanel.Tab = .timers
    @State private var inputs: [(uid: String, name: String, channels: Int)] = []

    private var on: Bool { assist.listening && assist.mode == .sermon }

    var body: some View {
        Menu {
            Button(on ? "Stop Listening" : "Listen to the Sermon") { toggle() }
            Section("Input") {
                inputButton(uid: "", name: "The Mac's Input (System Settings)")
                ForEach(inputs, id: \.uid) { inputButton(uid: $0.uid, name: $0.name) }
                if !assist.deviceUID.isEmpty, !inputs.contains(where: { $0.uid == assist.deviceUID }) {
                    inputButton(uid: assist.deviceUID, name: "Last Used Input (not connected)")
                }
            }
        } label: {
            TopBarCellLabel("Listen", systemImage: on ? "mic.fill" : "mic",
                            tint: on ? .white : nil, plate: on ? HopeStyle.live : nil)
        } primaryAction: {
            toggle()
        }
        .topBarMenu()
        // Read when the menu could open, so a microphone plugged in since shows.
        .onHover { inside in if inside { inputs = LiveTranscriber.inputDevices() } }
        .onAppear { inputs = LiveTranscriber.inputDevices() }
        .help(on ? "Stop listening to the sermon. Hold to choose the input."
                 : "Listen to the sermon: transcribe it and catch every Bible reference. Hold to choose the input.")
    }

    private func inputButton(uid: String, name: String) -> some View {
        Toggle(name, isOn: Binding(get: { assist.deviceUID == uid }, set: { if $0 { assist.deviceUID = uid } }))
    }

    private func toggle() {
        if on {
            assist.stop()
        } else {
            tab = .sermon
            Task { await assist.startSermon() }
        }
    }
}

// MARK: Sound

/// Where Screens' sound goes: the menu lists every output, and the choice
/// is the same one as Settings › Media › Sound Output, kept through a quit
/// and a restart. The label says which while one is pinned.
struct TopBarSoundCell: View {
    @State private var mixes = AudioMixInventory.shared
    @State private var outputs = AudioOutputInventory.shared
    @State private var devices: [AudioOutputDevice] = []

    var body: some View {
        // Read through the inventories so a change elsewhere redraws the label.
        let chosen = outputs.entry(id: mixes.primaryToken(mixId: AudioMixInventory.mainID))
        let uid = chosen?.deviceUID ?? ""
        Menu {
            Section("Play Through") {
                choice(uid: "", name: "The Mac's Output (follows macOS)", chosen: uid)
                ForEach(devices, id: \.uid) { choice(uid: $0.uid, name: $0.name, chosen: uid) }
                if !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
                    choice(uid: uid, name: "\(chosen?.name ?? "Chosen Output") (not connected)", chosen: uid)
                }
            }
            Divider()
            Button("Sound Settings…") { SettingsRouter.shared.open(.media) }
        } label: {
            TopBarCellLabel("Sound", systemImage: uid.isEmpty ? "speaker.wave.2" : "headphones",
                            selected: !uid.isEmpty)
        }
        .topBarMenu()
        .onHover { inside in if inside { devices = AudioDeviceList.outputDevices() } }
        .onAppear { devices = AudioDeviceList.outputDevices() }
        .help(uid.isEmpty
              ? "Sound plays wherever macOS sends it. Click to keep it on one device."
              : "Sound always plays through \(chosen?.name ?? "the chosen output"). Click to change.")
    }

    private func choice(uid: String, name: String, chosen: String) -> some View {
        Toggle(name, isOn: Binding(get: { chosen == uid }, set: { if $0 { SoundOutputChoice.choose(uid) } }))
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
    /// Hears when the window goes in and out of full screen.
    var onFullScreen: (Bool) -> Void = { _ in }

    final class ChromeView: NSView {
        var onFullScreen: (Bool) -> Void = { _ in }
        private weak var configured: NSWindow?
        private var toolbarWatch: NSKeyValueObservation?
        private var transparencyWatch: NSKeyValueObservation?
        private var fullScreenWatches: [NSObjectProtocol] = []
        /// In full screen macOS draws the toolbar in a window of its own,
        /// opaque and above this one. The empty toolbar that centres the
        /// traffic lights would cover the top bar there, so the window goes
        /// without it until it leaves full screen.
        private var inFullScreen = false

        /// The chrome view each window was last set up by. When SwiftUI
        /// rebuilds the workspace, the new view sets the window up before
        /// the old one is dismantled; the old one must then leave it alone.
        /// It used to put the title bar back to opaque, and an opaque title
        /// bar takes every click on the top bar while it still shows (0.23.1).
        private static let owners = NSMapTable<NSWindow, ChromeView>.weakToWeakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }

        func configure(_ window: NSWindow) {
            configured = window
            Self.owners.setObject(self, forKey: window)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            watchFullScreen(window)
            if window.styleMask.contains(.fullScreen) { enterFullScreen(window) } else { installToolbar(window) }
            #if DEBUG
            // Screenshots of full screen without UI scripting: SCREENS_FULL_SCREEN=1.
            if ProcessInfo.processInfo.environment["SCREENS_FULL_SCREEN"] == "1", !window.styleMask.contains(.fullScreen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.toggleFullScreen(nil)
                }
            }
            #endif
            // SwiftUI may take its toolbar away when its own items change
            // (the split view's, between modes); without one the title bar
            // shrinks and the traffic lights jump up off the bar's centre.
            toolbarWatch = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard window.toolbar == nil, self?.configured === window, self?.inFullScreen == false else { return }
                    DispatchQueue.main.async { self?.installToolbar(window) }
                }
            }
            // Whatever turns the title bar opaque again, the bar's buttons
            // stop taking clicks, so it is put straight back.
            transparencyWatch = window.observe(\.titlebarAppearsTransparent, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard !window.titlebarAppearsTransparent, self?.configured === window else { return }
                    DispatchQueue.main.async {
                        guard self?.configured === window else { return }
                        window.titlebarAppearsTransparent = true
                    }
                }
            }
        }

        private func watchFullScreen(_ window: NSWindow) {
            fullScreenWatches.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            fullScreenWatches = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.enterFullScreen(window) }
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.exitFullScreen(window) }
                },
            ]
            #if DEBUG
            fullScreenWatches.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { TopBarWindowChrome.logFullScreen(window) }
            })
            #endif
        }

        private func enterFullScreen(_ window: NSWindow) {
            guard configured === window else { return }
            inFullScreen = true
            window.toolbar = nil
            onFullScreen(true)
        }

        private func exitFullScreen(_ window: NSWindow) {
            guard configured === window else { return }
            inFullScreen = false
            installToolbar(window)
            onFullScreen(false)
        }

        private func installToolbar(_ window: NSWindow) {
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: TopBarWindowChrome.toolbarID)
            }
            window.toolbarStyle = .unified
        }

        func restore() {
            fullScreenWatches.forEach(NotificationCenter.default.removeObserver)
            fullScreenWatches = []
            toolbarWatch?.invalidate()
            toolbarWatch = nil
            transparencyWatch?.invalidate()
            transparencyWatch = nil
            guard let window = configured else { return }
            configured = nil
            // A newer workspace has the window now.
            guard Self.owners.object(forKey: window) === self else { return }
            Self.owners.removeObject(forKey: window)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            if window.toolbar?.identifier == TopBarWindowChrome.toolbarID { window.toolbar = nil }
        }
    }

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onFullScreen = onFullScreen
        return view
    }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.onFullScreen = onFullScreen }

    #if DEBUG
    /// What full screen looks like without a screenshot: every window the
    /// app has on screen, the main window's insets and where its top bar's
    /// space is. SCREENS_FULL_SCREEN=1 enters full screen and logs this.
    static func logFullScreen(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["SCREENS_FULL_SCREEN"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var lines = ["full screen: screen \(window.screen?.frame ?? .zero) window \(window.frame) toolbar \(window.toolbar?.identifier ?? "none")"]
            if let content = window.contentView {
                lines.append("content \(content.frame) safeArea \(content.safeAreaInsets)")
            }
            for other in NSApp.windows where other.isVisible {
                lines.append("window \(type(of: other)) level \(other.level.rawValue) frame \(other.frame) opaque \(other.isOpaque) alpha \(other.alphaValue) ignoresMouse \(other.ignoresMouseEvents) onScreen \(other.isOnActiveSpace)")
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
    #endif
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
    /// The plan's series theme in the editor (the theme library without one).
    var theme: () -> Void
    var scripture: () -> Void
    var media: () -> Void
}

/// Laid out as the operator asked for it: Search; the plan's pin; Present,
/// Edit and the theme editor; the Bible; then, at the right, the media bin,
/// listening and where the sound goes, the slide transition, More, Clear,
/// and the screens' lights. Everything else (Schedule, songs, points, the
/// sermon notes, the stage display) is in More.
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
            TopBarGroup {
                modeCell(.present, title: "Present", symbol: "play.rectangle", help: "Present (⌘1)")
                modeCell(.edit, title: "Edit", symbol: "square.3.layers.3d", help: "Edit: slides, layers and zoom (⌘2)")
                themeCell
            }
            TopBarGroup { bibleCell }
            Spacer(minLength: 12)
            TopBarGroup {
                mediaCell
                TopBarListenCell()
                TopBarSoundCell()
            }
            if let controls {
                TopBarGroup {
                    TransitionChip(
                        glyph: .presentations,
                        kindKey: SlideTransitionDefault.kindKey, durationKey: SlideTransitionDefault.durationKey,
                        fallbackKind: SlideTransitionDefault.kind.rawValue, fallbackDuration: SlideTransitionDefault.duration,
                        showSlider: false, showsName: true, inTopBar: true)
                }
                TopBarGroup { moreCell }
                // Clear All is also in the bar under the slides, so a
                // narrow window lets this one go first.
                if fit == .full {
                    TopBarGroup { ClearChip(controls: controls, inTopBar: true) }
                }
            } else {
                TopBarGroup { moreCell }
            }
            if fit != .tight {
                TopBarGroup {
                    ForEach(ShowScreen.inUse) { ScreenStatusCell(role: $0, render: render) }
                }
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

    // MARK: Cells

    private func modeCell(_ cellMode: AppMode, title: String, symbol: String, help: String) -> some View {
        Button { modeRaw = cellMode.rawValue } label: {
            TopBarCellLabel(title, systemImage: symbol, selected: mode == cellMode)
        }
        .buttonStyle(TopBarButtonStyle())
        .help(help)
    }

    /// A click opens the plan's series theme in the theme editor; the menu
    /// opens any other.
    private var themeCell: some View {
        Menu { themes() } label: {
            TopBarCellLabel("Theme", systemImage: "paintpalette")
        } primaryAction: {
            actions.theme()
        }
        .topBarMenu()
        .help("Open this plan's theme in the theme editor. Hold or click the arrow for the others.")
    }

    /// A click adds scripture; the menu has listening for references and the Bible theme.
    private var bibleCell: some View {
        Menu { scriptureMenu() } label: {
            TopBarCellLabel("Bible", systemImage: "book")
        } primaryAction: {
            actions.scripture()
        }
        .topBarMenu()
        .help("Add scripture slides (⌘⇧B). Hold for listening and the Bible theme.")
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

    private var moreCell: some View {
        Menu { more() } label: { TopBarCellLabel("More", systemImage: "ellipsis.circle") }
            .topBarMenu()
            .help("Schedule, songs, sermon points and notes, the stage display, Timers & Macros, Screen Setup")
    }
}
