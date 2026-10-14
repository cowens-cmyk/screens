import AppKit
import OutputEngine
import RenderEngine
import SwiftUI

/// The three screens this app drives: what the room sees, what goes over
/// the camera, and what the platform sees. There are no others.
enum ShowScreen: String, CaseIterable, Identifiable {
    case audience, livestream, stage

    var id: String { rawValue }

    var name: String {
        switch self {
        case .audience: "Audience"
        case .livestream: "Livestream"
        case .stage: "Stage"
        }
    }

    var role: ScreenRole { self == .stage ? .confidence : .audience }

    var summary: String {
        switch self {
        case .audience: "The slides, media and alerts the room sees."
        case .livestream: "Laid over the camera: transparent, a lower third, or the full slide."
        case .stage: "Lyrics, the next slide, clock and timers for the platform."
        }
    }

    @MainActor
    func target(_ setup: ShowSetup = .shared) -> String {
        switch self {
        case .audience: setup.audienceTarget
        case .livestream: setup.streamTarget
        case .stage: setup.stageTarget
        }
    }

    @MainActor
    func setTarget(_ id: String, _ setup: ShowSetup = .shared) {
        switch self {
        case .audience: if setup.audienceTarget != id { setup.audienceTarget = id }
        case .livestream: if setup.streamTarget != id { setup.streamTarget = id }
        case .stage: if setup.stageTarget != id { setup.stageTarget = id }
        }
    }

    @MainActor
    func screen(in outputs: OutputManager) -> PlaceholderScreen? {
        guard let id = UUID(uuidString: target()) else { return nil }
        return outputs.placeholderScreens.first { $0.id == id }
    }
}

@MainActor
enum ShowScreens {
    /// Runs at launch, before NDI and DeckLink restore their outputs: keeps
    /// one screen per role, makes any that are missing, and drops the rest.
    /// A screen already chosen for a role in Show Setup is kept (renamed if
    /// needed) so a working output survives the move to three screens.
    static func ensure(render: RenderContext) {
        let outputs = render.outputs
        var claimed: Set<UUID> = []
        for role in ShowScreen.allCases {
            let existing = adoptable(for: role, in: outputs, excluding: claimed)
            let screen: PlaceholderScreen?
            if let existing {
                screen = existing.name == role.name
                    ? existing
                    : outputs.reconfigurePlaceholderScreen(
                        id: existing.id, name: role.name, width: existing.width,
                        height: existing.height, framesPerSecond: existing.framesPerSecond)
            } else {
                screen = outputs.addPlaceholderScreen(name: role.name, width: 1920, height: 1080)
                DiagnosticsStore.shared.note("screens.created", detail: role.name)
            }
            guard let screen else { continue }
            claimed.insert(screen.id)
            outputs.setRole(role.role, forScreen: screen.id)
            role.setTarget(screen.id.uuidString)
            // Slices, masks and keystone placement were edited in the old
            // Screen Configuration, which is gone; nothing should be left
            // bending a screen that no one can see the setting for.
            for slice in outputs.screenSlices[screen.id] ?? [] {
                outputs.removeSlice(id: slice.id)
            }
            if !outputs.masks(forScreen: screen.id).isEmpty {
                outputs.setMasks([], forScreen: screen.id)
            }
            if outputs.placement(forSlice: screen.id) != nil {
                outputs.setPlacement(nil, forSlice: screen.id)
            }
        }
        // NDI and DeckLink haven't restored yet; they skip screens that are
        // gone, so nothing needs switching off here.
        for extra in outputs.placeholderScreens where !claimed.contains(extra.id) {
            outputs.removePlaceholderScreen(id: extra.id)
            DiagnosticsStore.shared.note("screens.removedExtra", detail: extra.name)
        }
    }

    private static func adoptable(
        for role: ShowScreen, in outputs: OutputManager, excluding claimed: Set<UUID>
    ) -> PlaceholderScreen? {
        let screens = outputs.placeholderScreens.filter { !claimed.contains($0.id) }
        if let id = UUID(uuidString: role.target()), let chosen = screens.first(where: { $0.id == id }) {
            return chosen
        }
        if let named = screens.first(where: { $0.name.caseInsensitiveCompare(role.name) == .orderedSame }) {
            return named
        }
        if role == .stage {
            return screens.first { outputs.role(forScreen: $0.id) == .confidence }
        }
        return nil
    }
}

/// Window › Screen Configuration and Settings › Show Setup: one card per
/// screen.
struct ThreeScreensView: View {
    let render: RenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ShowScreen.allCases) { role in
                if let screen = role.screen(in: render.outputs) {
                    ScreenCard(role: role, screen: screen, render: render)
                }
            }
        }
        .task { DeckLinkDeviceCatalog.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            DeckLinkDeviceCatalog.shared.refresh()
        }
    }
}

private struct ScreenCard: View {
    let role: ShowScreen
    let screen: PlaceholderScreen
    let render: RenderContext

    @AppStorage("screens.livestream.alphaKey") private var alphaKey = false
    @AppStorage("screens.livestream.keyMode") private var keyModeRaw = Int(DeckLinkAlphaKey.externalKey.rawValue)

    private var outputs: OutputManager { render.outputs }
    private var catalog: DeckLinkDeviceCatalog { .shared }
    private var deckLinkBacking: DeckLinkScreenOutputs.Backing? {
        DeckLinkScreenOutputs.shared.backing(for: screen.id)
    }
    private var ndiOn: Bool { NDIScreenOutputs.shared.status(for: screen.id) != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview
                .frame(width: 176)
                .aspectRatio(CGFloat(screen.width) / CGFloat(max(1, screen.height)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.separator.opacity(0.6)))
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).font(.headline)
                    Text(role.summary).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Output") {
                    Picker("", selection: Binding(get: { currentOutput }, set: choose)) {
                        Text("None").tag("none")
                        if !outputs.displays.isEmpty { Divider() }
                        ForEach(outputs.displays) { display in
                            Text(display.name).tag("display:\(display.uuid)")
                        }
                        if let backing = outputs.placeholderDevices[screen.id],
                           !outputs.displays.contains(where: { $0.uuid == backing }) {
                            Text("\(outputs.placeholderDeviceNames[screen.id] ?? "Display") (disconnected)")
                                .tag("display:\(backing)")
                        }
                        if !deckLinkPorts.isEmpty { Divider() }
                        ForEach(deckLinkPorts) { device in
                            Text("DeckLink: \(device.name)").tag("decklink:\(device.persistentID)")
                        }
                        Divider()
                        Text("NDI").tag("ndi")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let status = outputStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Resolution") {
                    ChipPicker(
                        options: [(1080, "1080p"), (2160, "4K")],
                        selection: Binding(get: { screen.height >= 2160 ? 2160 : 1080 }, set: setResolution))
                }
                if role == .livestream {
                    alphaKeyRow
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var preview: some View {
        if role == .livestream {
            ZStack {
                Checkerboard()
                TransparentScenePreview(
                    compositor: render.compositor,
                    provider: outputs.previewProvider(for: screen.id.uuidString))
            }
        } else {
            LiveSceneView(render: render, screenTargetID: screen.id.uuidString)
        }
    }

    // MARK: Output

    /// DeckLink ports that can send. A port mapped as an input in Desktop
    /// Video Setup is left for capture.
    private var deckLinkPorts: [DeckLinkHelperDevice] {
        catalog.devices.filter { device in
            catalog.displayModes[device.persistentID]?.isEmpty != true
                || deckLinkBacking?.devicePersistentID == device.persistentID
        }
    }

    private var currentOutput: String {
        if let backing = deckLinkBacking { return "decklink:\(backing.devicePersistentID)" }
        if ndiOn { return "ndi" }
        if let display = outputs.placeholderDevices[screen.id] { return "display:\(display)" }
        return "none"
    }

    private func choose(_ token: String) {
        guard token != currentOutput else { return }
        if token.hasPrefix("decklink:"),
           let id = Int64(token.dropFirst("decklink:".count)),
           let device = catalog.devices.first(where: { $0.persistentID == id }) {
            DeckLinkScreenOutputs.shared.enable(
                screenID: screen.id, device: device, keying: keying(for: device), render: render)
        } else if token == "ndi" {
            NDIScreenOutputs.shared.enable(screenID: screen.id, render: render)
        } else {
            NDIScreenOutputs.shared.disable(screenID: screen.id)
            DeckLinkScreenOutputs.shared.disable(screenID: screen.id, render: render)
            let display = token.hasPrefix("display:") ? String(token.dropFirst("display:".count)) : nil
            outputs.assignPlaceholderDevice(placeholderID: screen.id, displayUUID: display)
        }
    }

    private var outputStatus: String? {
        if deckLinkBacking != nil {
            switch DeckLinkScreenOutputs.shared.status(for: screen.id) {
            case .sending:
                let detail = DeckLinkScreenOutputs.shared.wireDetail(for: screen.id)
                return detail.isEmpty ? "Sending" : "Sending · \(detail)"
            case .starting: return "Starting…"
            case .interrupted: return "Reconnecting…"
            case .failed(let message): return message
            case .idle, nil: return nil
            }
        }
        if ndiOn {
            switch NDIScreenOutputs.shared.status(for: screen.id) {
            case .sending(let name): return "Sending as \u{201C}\(name)\u{201D}"
            case .starting: return "Starting…"
            case .interrupted: return "Helper restarting…"
            case .failed(let message): return message
            case .idle, nil: return nil
            }
        }
        if let backing = outputs.placeholderDevices[screen.id],
           !outputs.displays.contains(where: { $0.uuid == backing }) {
            return "That display isn't connected. The screen comes back when it is."
        }
        return nil
    }

    // MARK: Resolution

    private func setResolution(_ height: Int) {
        let width = height == 2160 ? 3840 : 1920
        guard width != screen.width || height != screen.height else { return }
        outputs.reconfigurePlaceholderScreen(
            id: screen.id, name: screen.name, width: width, height: height,
            framesPerSecond: screen.framesPerSecond)
        // NDI and DeckLink size their frames when they start.
        if ndiOn {
            NDIScreenOutputs.shared.enable(screenID: screen.id, render: render)
        }
        DeckLinkScreenOutputs.shared.refreshCarry(for: screen.id, render: render)
    }

    // MARK: Alpha key

    private func keying(for device: DeckLinkHelperDevice) -> DeckLinkAlphaKey {
        guard role == .livestream, alphaKey else { return .off }
        let wanted = DeckLinkAlphaKey(rawValue: Int32(keyModeRaw)) ?? .externalKey
        switch wanted {
        case .externalKey where device.supportsExternalKeying: return .externalKey
        case .internalKey where device.supportsInternalKeying: return .internalKey
        default:
            if device.supportsExternalKeying { return .externalKey }
            if device.supportsInternalKeying { return .internalKey }
            return .off
        }
    }

    private var deckLinkDevice: DeckLinkHelperDevice? {
        deckLinkBacking.flatMap { backing in
            catalog.devices.first { $0.persistentID == backing.devicePersistentID }
        }
    }

    private func applyKeying() {
        guard let device = deckLinkDevice else { return }
        DeckLinkScreenOutputs.shared.setKeying(
            screenID: screen.id, keying: keying(for: device), render: render)
    }

    @ViewBuilder
    private var alphaKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alpha key (transparent)", isOn: Binding(
                get: { alphaKey },
                set: { alphaKey = $0; applyKeying() }
            ))
            .disabled(deckLinkDevice == nil)
            if let device = deckLinkDevice, alphaKey,
               device.supportsInternalKeying, device.supportsExternalKeying {
                ChipPicker(
                    options: [(DeckLinkAlphaKey.externalKey.rawValue, "External"),
                              (DeckLinkAlphaKey.internalKey.rawValue, "Internal")],
                    selection: Binding(
                        get: { Int32(keyModeRaw) },
                        set: { keyModeRaw = Int($0); applyKeying() }))
            }
            Text(alphaCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alphaCaption: String {
        guard deckLinkDevice != nil else {
            return "Needs a DeckLink output. NDI carries transparency on its own."
        }
        guard alphaKey else { return "Off: the switcher gets the full picture." }
        switch deckLinkBacking?.keying {
        case .externalKey?: return "External: fill and key on separate connectors for the switcher's keyer."
        case .internalKey?: return "Internal: the card keys over the video at its SDI input."
        default: return "This DeckLink port can't key."
        }
    }
}

/// Window › Screen Configuration.
struct OutputsWindow: View {
    let render: RenderContext?

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        Group {
            if let render {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ThreeScreensView(render: render)
                        Text("NDI® is a registered trademark of Vizrt NDI AB")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(16)
                }
            } else {
                Text("Metal is not available on this machine.")
                    .padding(40)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color.basePlane)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
    }
}
