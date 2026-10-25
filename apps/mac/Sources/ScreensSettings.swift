import AppKit
import CoreGraphics
import OutputEngine
import RenderEngine
import SwiftUI

/// Settings › Screens: the Mac's displays drawn where they sit, each one
/// given to Audience, Livestream or Stage by dragging or picking; then each
/// screen's own output, resolution and options; then NDI and DeckLink.
/// Everything goes through ScreenOutput, the same logic the old Screen
/// Configuration window used.
struct ScreensSettingsPane: View {
    let render: RenderContext

    @State private var selected: DisplayUUID?

    private var outputs: OutputManager { render.outputs }

    private var selectedDisplay: DisplaySnapshot? {
        outputs.displays.first { $0.uuid == selected }
    }

    var body: some View {
        Form {
            Section {
                DisplayArrangementView(render: render, selection: $selected)
                    .settingsAnchor("screens.arrangement")
            } header: {
                Text("Displays")
            } footer: {
                Text("Drag Audience, Livestream or Stage onto a display, or click a display and choose below. A display shows one screen. Right-click a display to identify it.")
            }
            if let display = selectedDisplay {
                SelectedDisplaySection(display: display, render: render)
            }
            ForEach(ShowScreen.allCases) { role in
                ScreenOutputSection(role: role, render: render)
            }
            NetworkOutputsSections(render: render)
        }
        .settingsForm()
        .onAppear { pickDefaultDisplay() }
        .onChange(of: outputs.displays.map(\.uuid)) { _, _ in pickDefaultDisplay() }
        .task { DeckLinkDeviceCatalog.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            DeckLinkDeviceCatalog.shared.refresh()
        }
    }

    /// Starts on a display that shows a screen, else one that isn't this
    /// Mac's own, so the first choice offered is the likely one.
    private func pickDefaultDisplay() {
        let displays = outputs.displays
        guard selected == nil || !displays.contains(where: { $0.uuid == selected }) else { return }
        selected = displays.first { ScreenRouting.role(on: $0.uuid, render: render) != nil }?.uuid
            ?? displays.first { !$0.isMain }?.uuid
            ?? displays.first?.uuid
    }
}

extension ShowScreen {
    /// The colour that marks this screen in the arrangement and its section.
    var tint: Color {
        switch self {
        case .audience: .blue
        case .livestream: .red
        case .stage: .orange
        }
    }
}

// MARK: - Arrangement

/// The connected displays to scale, positioned as macOS arranges them, like
/// System Settings › Displays. A display showing a screen previews it.
struct DisplayArrangementView: View {
    let render: RenderContext
    @Binding var selection: DisplayUUID?

    @State private var modes: [DisplayUUID: DisplayModeInfo] = [:]
    @State private var dropTarget: DisplayUUID?

    private var outputs: OutputManager { render.outputs }

    /// Changes whenever the displays or their modes might have.
    private var displayKey: String {
        outputs.displays.map(\.uuid).joined(separator: ",") + "#\(outputs.reconfigurationCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Drag to a display:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(ShowScreen.allCases) { role in
                    RoleChip(role: role)
                        .draggable(role.rawValue) { RoleChip(role: role) }
                        .help("Drag onto a display to show \(role.name) there")
                }
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                canvas(in: proxy.size)
            }
            .frame(height: 212)
            .background(
                Color.black.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.vertical, 4)
        .task(id: displayKey) {
            var found: [DisplayUUID: DisplayModeInfo] = [:]
            for display in outputs.displays { found[display.uuid] = DisplayModeInfo.of(display) }
            modes = found
        }
    }

    @ViewBuilder
    private func canvas(in size: CGSize) -> some View {
        let displays = outputs.displays
        let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
        if displays.isEmpty || bounds.isNull || bounds.width <= 0 || bounds.height <= 0 {
            Text("No displays found.")
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
        } else {
            let margin: CGFloat = 16
            let scale = min((size.width - margin * 2) / bounds.width, (size.height - margin * 2) / bounds.height)
            let originX = (size.width - bounds.width * scale) / 2
            let originY = (size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    // AppKit's y runs up; the canvas's runs down.
                    let rect = CGRect(
                        x: originX + (display.frame.minX - bounds.minX) * scale,
                        y: originY + (bounds.maxY - display.frame.maxY) * scale,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    ).insetBy(dx: 2, dy: 2)
                    tile(display, size: rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func tile(_ display: DisplaySnapshot, size: CGSize) -> some View {
        let role = ScreenRouting.role(on: display.uuid, render: render)
        let base = DisplayTile(
            display: display, mode: modes[display.uuid], role: role, render: render, size: size,
            selected: selection == display.uuid, targeted: dropTarget == display.uuid
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = display.uuid }
        .contextMenu {
            ForEach(ShowScreen.allCases) { candidate in
                Toggle(candidate.name, isOn: Binding(
                    get: { role == candidate },
                    set: { _ in ScreenRouting.assign(display: display.uuid, to: candidate, render: render) }))
            }
            Toggle("None", isOn: Binding(
                get: { role == nil },
                set: { _ in ScreenRouting.assign(display: display.uuid, to: nil, render: render) }))
            Divider()
            Button("Identify") { ScreenIdentifier.flash(display, role: role) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first.flatMap(ShowScreen.init(rawValue:)) else { return false }
            ScreenRouting.assign(display: display.uuid, to: dropped, render: render)
            selection = display.uuid
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = display.uuid
            } else if dropTarget == display.uuid {
                dropTarget = nil
            }
        }
        if let role {
            // Dragging a display's screen to another display moves it there.
            base.draggable(role.rawValue) { RoleChip(role: role) }
        } else {
            base
        }
    }
}

private struct RoleChip: View {
    let role: ShowScreen

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(role.tint).frame(width: 7, height: 7)
            Text(role.name).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(role.tint.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(role.tint.opacity(0.55), lineWidth: 1))
    }
}

private struct DisplayTile: View {
    let display: DisplaySnapshot
    let mode: DisplayModeInfo?
    let role: ShowScreen?
    let render: RenderContext
    let size: CGSize
    let selected: Bool
    let targeted: Bool

    private var roomy: Bool { size.width >= 120 && size.height >= 70 }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                if display.isMain {
                    // The menu bar, as System Settings marks the main display.
                    Rectangle().fill(Color.white.opacity(0.35)).frame(height: max(3, size.height * 0.04))
                }
                Spacer(minLength: 0)
                labels
                Spacer(minLength: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected || targeted ? 3 : (role == nil ? 1 : 2))
        )
        .help(helpText)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let role, role.screen(in: render.outputs) != nil {
            let target = role.target()
            ZStack {
                if role == .livestream {
                    Checkerboard()
                    TransparentScenePreview(
                        compositor: render.compositor,
                        provider: render.outputs.previewProvider(for: target),
                        maximumFramesPerSecond: 6)
                } else {
                    LiveSceneView(render: render, screenTargetID: target, maximumFramesPerSecond: 6)
                }
                Color.black.opacity(0.35)
            }
        } else {
            LinearGradient(
                colors: [Color(white: 0.24), Color(white: 0.13)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private var labels: some View {
        VStack(spacing: 3) {
            if let role {
                Text(role.name)
                    .font(.system(size: roomy ? 12 : 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(role.tint, in: Capsule())
                    .foregroundStyle(.white)
            } else if roomy {
                Text("Not used")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if roomy {
                Text(display.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let mode {
                    Text(mode.shortText)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .shadow(color: .black.opacity(0.6), radius: 2)
    }

    private var borderColor: Color {
        if targeted || selected { return .accentColor }
        return role?.tint ?? Color.white.opacity(0.2)
    }

    private var helpText: String {
        var parts = [display.name]
        if let mode { parts.append(mode.text) }
        parts.append(role.map { "Shows \($0.name)" } ?? "Not used")
        return parts.joined(separator: " · ")
    }
}

/// The chosen display: what it is and which screen it shows.
private struct SelectedDisplaySection: View {
    let display: DisplaySnapshot
    let render: RenderContext

    var body: some View {
        let role = ScreenRouting.role(on: display.uuid, render: render)
        Section {
            Picker("Shows", selection: Binding(
                get: { role },
                set: { ScreenRouting.assign(display: display.uuid, to: $0, render: render) }
            )) {
                Text("None").tag(ShowScreen?.none)
                Divider()
                ForEach(ShowScreen.allCases) { Text($0.name).tag(ShowScreen?.some($0)) }
            }
            .frame(maxWidth: 360)
            LabeledContent("Resolution") {
                Text(DisplayModeInfo.of(display).text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Identify") {
                Button("Show Name on Display") { ScreenIdentifier.flash(display, role: role) }
            }
        } header: {
            Text(display.isMain ? "\(display.name) (main display)" : display.name)
        } footer: {
            if display.isMain {
                Text("This is the display with the menu bar. A screen shown here covers the app while it is live.")
            }
        }
    }
}

// MARK: - Screens

/// One screen's output, resolution and options, with a live preview.
private struct ScreenOutputSection: View {
    let role: ShowScreen
    let render: RenderContext

    @AppStorage(ScreenOutput.alphaKeyKey) private var alphaKey = false
    @AppStorage(ScreenOutput.keyModeKey) private var keyModeRaw = Int(DeckLinkAlphaKey.externalKey.rawValue)
    @Bindable private var setup = ShowSetup.shared

    private var outputs: OutputManager { render.outputs }

    var body: some View {
        if let output = ScreenOutput(role, render: render) {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    preview(output)
                        .frame(width: 192, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.separator.opacity(0.6)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(role.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let status = output.status {
                            Label(status, systemImage: output.isProblem ? "exclamationmark.triangle.fill" : "dot.radiowaves.right")
                                .font(.subheadline)
                                .foregroundStyle(output.isProblem ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .settingsAnchor("screens.\(role.rawValue)")
                Picker("Output", selection: Binding(get: { output.current }, set: output.choose)) {
                    outputChoices(output)
                }
                .frame(maxWidth: 360)
                Picker("Resolution", selection: Binding(get: { output.resolutionHeight }, set: output.setResolution)) {
                    Text("1080p").tag(1080)
                    Text("4K").tag(2160)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                switch role {
                case .livestream: livestreamOptions(output)
                case .stage: stageOptions
                case .audience: EmptyView()
                }
            } header: {
                HStack(spacing: 6) {
                    Circle().fill(role.tint).frame(width: 8, height: 8)
                    Text(role.name)
                }
            } footer: {
                if role == .livestream {
                    Text(output.alphaCaption)
                }
            }
        }
    }

    @ViewBuilder
    private func preview(_ output: ScreenOutput) -> some View {
        if role == .livestream {
            ZStack {
                Checkerboard()
                TransparentScenePreview(
                    compositor: render.compositor,
                    provider: outputs.previewProvider(for: output.screen.id.uuidString),
                    maximumFramesPerSecond: 15)
            }
        } else {
            LiveSceneView(render: render, screenTargetID: output.screen.id.uuidString, maximumFramesPerSecond: 15)
        }
    }

    @ViewBuilder
    private func outputChoices(_ output: ScreenOutput) -> some View {
        Text("None").tag("none")
        if !outputs.displays.isEmpty { Divider() }
        ForEach(outputs.displays) { display in
            Text(display.isMain ? "\(display.name) (main display)" : display.name)
                .tag("display:\(display.uuid)")
        }
        if let backing = outputs.placeholderDevices[output.screen.id],
           !outputs.displays.contains(where: { $0.uuid == backing }) {
            Text("\(outputs.placeholderDeviceNames[output.screen.id] ?? "Display") (disconnected)")
                .tag("display:\(backing)")
        }
        let ports = output.deckLinkPorts
        if !ports.isEmpty { Divider() }
        ForEach(ports) { device in
            Text("DeckLink: \(device.name)").tag("decklink:\(device.persistentID)")
        }
        Divider()
        Text("NDI").tag("ndi")
    }

    @ViewBuilder
    private func livestreamOptions(_ output: ScreenOutput) -> some View {
        Picker("Shows", selection: $setup.streamMode) {
            ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Toggle(isOn: Binding(
            get: { alphaKey },
            set: { alphaKey = $0; output.applyKeying() }
        )) {
            SettingsLabel(entry: SettingsIndex.entry("screens.alphaKey")
                ?? SettingsEntry(id: "screens.alphaKey", category: .screens, title: "Alpha key (transparent)"))
        }
        .toggleStyle(.switch)
        .disabled(output.deckLinkDevice == nil)
        .settingsAnchor("screens.alphaKey")
        if let device = output.deckLinkDevice, alphaKey,
           device.supportsInternalKeying, device.supportsExternalKeying {
            Picker("Keying", selection: Binding(
                get: { Int32(keyModeRaw) },
                set: { keyModeRaw = Int($0); output.applyKeying() }
            )) {
                Text("External").tag(DeckLinkAlphaKey.externalKey.rawValue)
                Text("Internal").tag(DeckLinkAlphaKey.internalKey.rawValue)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var stageOptions: some View {
        Picker("Shows", selection: $setup.stageMode) {
            ForEach(ShowSetup.StageMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Toggle("Follow what's live", isOn: $setup.stageFollowsItems)
            .toggleStyle(.switch)
    }
}

// MARK: - NDI and DeckLink

/// NDI and the DeckLink ports alongside the displays: which screens each
/// carries, the NDI network, and what the DeckLink driver reports.
private struct NetworkOutputsSections: View {
    let render: RenderContext

    @State private var catalog = DeckLinkDeviceCatalog.shared

    /// Every port that can send, and any port a screen already uses.
    private var ports: [DeckLinkHelperDevice] {
        catalog.devices.filter { device in
            catalog.displayModes[device.persistentID]?.isEmpty != true
                || !ScreenRouting.roles(onDeckLink: device.persistentID, render: render).isEmpty
        }
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    ForEach(ShowScreen.allCases) { role in
                        roleToggle(role, isOn: ScreenOutput(role, render: render)?.ndiOn == true) { on in
                            ScreenOutput(role, render: render)?.choose(on ? "ndi" : "none")
                        }
                    }
                }
            } label: {
                SettingsLabel(entry: SettingsIndex.entry("screens.ndi")
                    ?? SettingsEntry(id: "screens.ndi", category: .screens, title: "Send over NDI"))
            }
            .settingsAnchor("screens.ndi")
            SettingsRow("network.ndi") {
                NDINetworkScopeControl()
            }
        } header: {
            Text("NDI")
        } footer: {
            Text("NDI\u{AE} is a registered trademark of Vizrt NDI AB")
        }
        Section {
            ForEach(ports) { device in
                LabeledContent(device.name) {
                    HStack(spacing: 6) {
                        let carried = ScreenRouting.roles(onDeckLink: device.persistentID, render: render)
                        ForEach(ShowScreen.allCases) { role in
                            roleToggle(role, isOn: carried.contains(role)) { on in
                                ScreenOutput(role, render: render)?.choose(on ? "decklink:\(device.persistentID)" : "none")
                            }
                        }
                    }
                }
            }
            DeckLinkSetupForm()
        } header: {
            Text("Blackmagic DeckLink")
        } footer: {
            Text("A port carries the screens switched on beside it. Ports mapped as inputs in Desktop Video Setup are left for capture.")
        }
    }

    private func roleToggle(_ role: ShowScreen, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(role.name, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(role.tint)
    }
}

// MARK: - Display details

/// A display's pixels and refresh rate, read from its current mode.
struct DisplayModeInfo: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    @MainActor
    static func of(_ display: DisplaySnapshot) -> DisplayModeInfo {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            let rate = mode.refreshRate > 0 ? mode.refreshRate : Double(display.maximumFramesPerSecond)
            return DisplayModeInfo(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: rate)
        }
        return DisplayModeInfo(
            pixelWidth: Int(display.frame.width), pixelHeight: Int(display.frame.height),
            refreshRate: Double(display.maximumFramesPerSecond))
    }

    var text: String {
        "\(pixelWidth) \u{D7} \(pixelHeight) at \(hertz)"
    }

    var shortText: String {
        "\(pixelWidth)\u{D7}\(pixelHeight) \u{B7} \(hertz)"
    }

    private var hertz: String {
        refreshRate.rounded() == refreshRate
            ? "\(Int(refreshRate)) Hz"
            : String(format: "%.2f Hz", refreshRate)
    }
}

/// Puts the display's name (and the screen it shows) in large type on that
/// display for a few seconds, above any output window, so the right
/// projector can be picked out from the booth.
@MainActor
enum ScreenIdentifier {
    private static var panels: [DisplayUUID: NSPanel] = [:]

    static func flash(_ display: DisplaySnapshot, role: ShowScreen?) {
        guard let screen = display.currentScreen() else { return }
        panels.removeValue(forKey: display.uuid)?.close()
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        // Output windows sit one above the menu bar; this goes over them.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: IdentifyCard(name: display.name, role: role))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        panels[display.uuid] = panel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard panels[display.uuid] === panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                panel.animator().alphaValue = 0
            }
            panel.close()
            if panels[display.uuid] === panel { panels.removeValue(forKey: display.uuid) }
        }
    }
}

private struct IdentifyCard: View {
    let name: String
    let role: ShowScreen?

    var body: some View {
        VStack(spacing: 10) {
            Text(role?.name ?? "Not used")
                .font(.system(size: 72, weight: .bold))
            Text(name)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(role?.tint ?? Color.white.opacity(0.4), lineWidth: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
