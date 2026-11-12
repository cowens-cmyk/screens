import AppKit
import OutputEngine
import RenderEngine
import SwiftUI

/// The screens this app drives: what the room sees, what goes over the
/// camera, and what the platform sees, plus the side TVs for a room that
/// has them. There are no others.
enum ShowScreen: String, CaseIterable, Identifiable {
    case audience, livestream, stage
    /// TVs beside the main screen: the room's slides with a song's lyrics
    /// drawn larger. Only there when turned on in Settings › Screens.
    case sideTVs

    var id: String { rawValue }

    var name: String {
        switch self {
        case .audience: "Audience"
        case .livestream: "Livestream"
        case .stage: "Stage"
        case .sideTVs: "Side TVs"
        }
    }

    var role: ScreenRole { self == .stage ? .confidence : .audience }

    var summary: String {
        switch self {
        case .audience: "The slides, media and alerts the room sees."
        case .livestream: "Laid over the camera: transparent, a lower third, or the full slide."
        case .stage: "Lyrics, the next slide, clock and timers for the platform."
        case .sideTVs: "The audience slides with song lyrics drawn larger, for TVs beside the main screen."
        }
    }

    /// The screens this Mac drives: the side TVs only when turned on.
    @MainActor
    static var inUse: [ShowScreen] {
        allCases.filter { $0 != .sideTVs || ShowSetup.shared.sideTVsOn }
    }

    @MainActor
    func target(_ setup: ShowSetup = .shared) -> String {
        switch self {
        case .audience: setup.audienceTarget
        case .livestream: setup.streamTarget
        case .stage: setup.stageTarget
        case .sideTVs: setup.sideTVsTarget
        }
    }

    @MainActor
    func setTarget(_ id: String, _ setup: ShowSetup = .shared) {
        switch self {
        case .audience: if setup.audienceTarget != id { setup.audienceTarget = id }
        case .livestream: if setup.streamTarget != id { setup.streamTarget = id }
        case .stage: if setup.stageTarget != id { setup.stageTarget = id }
        case .sideTVs: if setup.sideTVsTarget != id { setup.sideTVsTarget = id }
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
        for role in ShowScreen.inUse {
            guard let screen = make(role, in: outputs, excluding: claimed) else { continue }
            claimed.insert(screen.id)
            // Slices, masks and keystone placement were edited in the old
            // Screen Configuration, which is gone; nothing should be left
            // bending a screen that no one can see the setting for. The side
            // TVs' second display is a whole-picture copy set in Settings ›
            // Screens, so it stays while it still has a display.
            for slice in outputs.screenSlices[screen.id] ?? []
            where role != .sideTVs || !ScreenOutput.isMirror(slice, outputs: outputs) {
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
        moveToSixtyOnce(outputs)
    }

    /// What a screen is made at: 1080p60, what the switcher runs.
    static let defaultFramesPerSecond = 60
    /// The rates Settings › Screens offers.
    static let frameRates = [24, 25, 30, 50, 60]
    private static let sixtyKey = "screens.movedToSixty.v1"

    /// Screens used to be made at 30 frames a second. Once, every screen
    /// still under 60 is moved to it; after that the rate is whatever
    /// Settings › Screens says, so one set back to 30 stays there.
    private static func moveToSixtyOnce(_ outputs: OutputManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sixtyKey) else { return }
        defaults.set(true, forKey: sixtyKey)
        for screen in outputs.placeholderScreens where screen.framesPerSecond < defaultFramesPerSecond {
            outputs.reconfigurePlaceholderScreen(
                id: screen.id, name: screen.name, width: screen.width, height: screen.height,
                framesPerSecond: defaultFramesPerSecond)
            keepDelayTime(outputs, screenID: screen.id, from: screen.framesPerSecond, to: defaultFramesPerSecond)
            DiagnosticsStore.shared.note(
                "screens.frameRate", detail: "\(screen.name): \(screen.framesPerSecond) to \(defaultFramesPerSecond)")
        }
    }

    /// A screen's video delay is counted in frames, so a change of frame
    /// rate keeps its time: 3 frames at 30 become 6 at 60. Its slices too.
    static func keepDelayTime(_ outputs: OutputManager, screenID: UUID, from old: Int, to new: Int) {
        guard old > 0, new > 0, old != new else { return }
        for id in [screenID] + (outputs.screenSlices[screenID] ?? []).map(\.id) {
            let frames = outputs.videoDelay(forScreen: id)
            guard frames > 0 else { continue }
            outputs.setVideoDelay(Int((Double(frames) * Double(new) / Double(old)).rounded()), forScreen: id)
        }
    }

    /// The role's screen, adopted from what's there or made, with its role
    /// and target set.
    private static func make(
        _ role: ShowScreen, in outputs: OutputManager, excluding claimed: Set<UUID>
    ) -> PlaceholderScreen? {
        let existing = adoptable(for: role, in: outputs, excluding: claimed)
        let screen: PlaceholderScreen?
        if let existing {
            screen = existing.name == role.name
                ? existing
                : outputs.reconfigurePlaceholderScreen(
                    id: existing.id, name: role.name, width: existing.width,
                    height: existing.height, framesPerSecond: existing.framesPerSecond)
        } else {
            screen = outputs.addPlaceholderScreen(
                name: role.name, width: 1920, height: 1080, framesPerSecond: defaultFramesPerSecond)
            DiagnosticsStore.shared.note("screens.created", detail: role.name)
        }
        guard let screen else { return nil }
        outputs.setRole(role.role, forScreen: screen.id)
        role.setTarget(screen.id.uuidString)
        return screen
    }

    /// Turns the side TVs on or off while the app runs. Off takes the
    /// screen away with everything carrying it (its displays, NDI and
    /// DeckLink ports) so nothing keeps sending a screen that's gone and the
    /// Mac stops drawing it.
    static func setSideTVs(_ on: Bool, render: RenderContext) {
        let setup = ShowSetup.shared
        let outputs = render.outputs
        if on {
            guard ScreenOutput(.sideTVs, render: render) == nil else {
                if !setup.sideTVsOn { setup.sideTVsOn = true }
                return
            }
            let taken = Set(ShowScreen.allCases.filter { $0 != .sideTVs }
                .compactMap { $0.screen(in: outputs)?.id })
            guard make(.sideTVs, in: outputs, excluding: taken) != nil else { return }
            setup.sideTVsOn = true
            DiagnosticsStore.shared.note("screens.sideTVs", detail: "on")
        } else {
            if let output = ScreenOutput(.sideTVs, render: render) {
                output.setMirror(nil)
                NDIScreenOutputs.shared.disable(screenID: output.screen.id)
                DeckLinkScreenOutputs.shared.disable(screenID: output.screen.id, render: render)
                outputs.assignPlaceholderDevice(placeholderID: output.screen.id, displayUUID: nil)
                outputs.removePlaceholderScreen(id: output.screen.id)
            }
            setup.sideTVsOn = false
            DiagnosticsStore.shared.note("screens.sideTVs", detail: "off")
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

/// What carries one of the three screens (a display, a DeckLink port, NDI
/// or nothing) and the changes to it. Settings › Screens draws it twice, as
/// a display's role in the arrangement and as the screen's own Output menu,
/// so both go through here.
@MainActor
struct ScreenOutput {
    static let alphaKeyKey = "screens.livestream.alphaKey"
    static let keyModeKey = "screens.livestream.keyMode"

    let role: ShowScreen
    let screen: PlaceholderScreen
    let render: RenderContext

    init?(_ role: ShowScreen, render: RenderContext) {
        guard let screen = role.screen(in: render.outputs) else { return nil }
        self.role = role
        self.screen = screen
        self.render = render
    }

    private var outputs: OutputManager { render.outputs }
    private var catalog: DeckLinkDeviceCatalog { .shared }

    var deckLinkBacking: DeckLinkScreenOutputs.Backing? {
        DeckLinkScreenOutputs.shared.backing(for: screen.id)
    }

    /// Every DeckLink port the screen goes out of.
    var deckLinkBackings: [DeckLinkScreenOutputs.Backing] {
        DeckLinkScreenOutputs.shared.backingList(for: screen.id)
    }

    var ndiOn: Bool { NDIScreenOutputs.shared.status(for: screen.id) != nil }

    /// The display showing this screen, when a display does.
    var display: DisplayUUID? {
        guard deckLinkBacking == nil, !ndiOn else { return nil }
        return outputs.placeholderDevices[screen.id]
    }

    /// DeckLink ports that can send. A port mapped as an input in Desktop
    /// Video Setup is left for capture.
    var deckLinkPorts: [DeckLinkHelperDevice] {
        catalog.devices.filter { device in
            catalog.displayModes[device.persistentID]?.isEmpty != true
                || deckLinkBackings.contains { $0.devicePersistentID == device.persistentID }
        }
    }

    /// "none", "display:<uuid>", "decklink:<id>", "decklink:several" or
    /// "ndi".
    var current: String {
        if deckLinkBackings.count > 1 { return Self.severalPortsToken }
        if let backing = deckLinkBacking { return "decklink:\(backing.devicePersistentID)" }
        if ndiOn { return "ndi" }
        if let display = outputs.placeholderDevices[screen.id] { return "display:\(display)" }
        return "none"
    }

    /// The Output menu's entry for a screen on more than one port. Choosing
    /// it changes nothing; the ports are set in the DeckLink section.
    static let severalPortsToken = "decklink:several"

    func choose(_ token: String) {
        guard token != current, token != Self.severalPortsToken else { return }
        defer {
            // The side TVs' second display copies the first, so it goes
            // when the screen leaves its display, and a copy left on the
            // display the screen just moved to has nothing left to show.
            if role == .sideTVs {
                if token.hasPrefix("display:") { pruneMirrors() } else { setMirror(nil) }
            }
        }
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

    /// The DeckLink section's switch for one port: on adds the port and
    /// keeps the screen's others, off takes this port away and leaves the
    /// rest. A screen on a display or NDI moves to DeckLink.
    func setDeckLink(_ device: DeckLinkHelperDevice, on: Bool) {
        if on {
            DeckLinkScreenOutputs.shared.enable(
                screenID: screen.id, device: device, keying: keying(for: device),
                adding: true, render: render)
        } else {
            DeckLinkScreenOutputs.shared.disable(
                screenID: screen.id, devicePersistentID: device.persistentID, render: render)
        }
    }

    // MARK: Second display

    /// A whole-picture copy of a screen on a display: how the side TVs go to
    /// a second display. The output windows draw it from the same scene as
    /// the first, so both TVs change on the same frame.
    static func isMirror(_ slice: OutputSliceState, outputs: OutputManager) -> Bool {
        slice.sourceRect == Compositor.fullSourceRect && outputs.placeholderDevices[slice.id] != nil
    }

    /// The side TVs' second display, when they're on two.
    var mirrorDisplay: DisplayUUID? {
        (outputs.screenSlices[screen.id] ?? [])
            .first { Self.isMirror($0, outputs: outputs) }
            .flatMap { outputs.placeholderDevices[$0.id] }
    }

    /// Shows the side TVs on a second display as well, or (nil) only on
    /// their first. Only while the first is a display: a copy of a screen
    /// that goes out over NDI or DeckLink would stop its own picture.
    func setMirror(_ wanted: DisplayUUID?) {
        guard wanted != mirrorDisplay || (outputs.screenSlices[screen.id]?.count ?? 0) > 1 else { return }
        for slice in outputs.screenSlices[screen.id] ?? [] {
            outputs.removeSlice(id: slice.id)
        }
        guard let wanted, role == .sideTVs, display != nil, wanted != display,
              let slice = outputs.addSlice(toScreen: screen.id, name: "\(role.name) 2")
        else { return }
        outputs.assignPlaceholderDevice(placeholderID: slice.id, displayUUID: wanted)
    }

    /// Drops copies whose display was given to something else.
    private func pruneMirrors() {
        for slice in outputs.screenSlices[screen.id] ?? [] where !Self.isMirror(slice, outputs: outputs) {
            outputs.removeSlice(id: slice.id)
        }
    }

    var status: String? {
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
        if let mirror = mirrorDisplay, !outputs.displays.contains(where: { $0.uuid == mirror }) {
            return "The second display isn't connected. It comes back when it is."
        }
        return nil
    }

    /// The status above is a fault, not news.
    var isProblem: Bool {
        if case .failed? = DeckLinkScreenOutputs.shared.status(for: screen.id) { return true }
        if case .failed? = NDIScreenOutputs.shared.status(for: screen.id) { return true }
        if deckLinkBacking == nil, !ndiOn, let backing = outputs.placeholderDevices[screen.id],
           !outputs.displays.contains(where: { $0.uuid == backing }) {
            return true
        }
        if let mirror = mirrorDisplay, !outputs.displays.contains(where: { $0.uuid == mirror }) {
            return true
        }
        return false
    }

    // MARK: Resolution

    var resolutionHeight: Int { screen.height >= 2160 ? 2160 : 1080 }

    func setResolution(_ height: Int) {
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

    // MARK: Frame rate

    var frameRate: Int { screen.framesPerSecond }

    func setFrameRate(_ framesPerSecond: Int) {
        guard framesPerSecond > 0, framesPerSecond != screen.framesPerSecond else { return }
        let before = screen.framesPerSecond
        outputs.reconfigurePlaceholderScreen(
            id: screen.id, name: screen.name, width: screen.width, height: screen.height,
            framesPerSecond: framesPerSecond)
        ShowScreens.keepDelayTime(outputs, screenID: screen.id, from: before, to: framesPerSecond)
        // NDI and DeckLink take their rate when they start.
        if ndiOn {
            NDIScreenOutputs.shared.enable(screenID: screen.id, render: render)
        }
        DeckLinkScreenOutputs.shared.refreshCarry(for: screen.id, render: render)
    }

    // MARK: Alpha key

    static var alphaKeyOn: Bool { UserDefaults.standard.bool(forKey: alphaKeyKey) }

    static var wantedKeyMode: DeckLinkAlphaKey {
        let raw = UserDefaults.standard.object(forKey: keyModeKey) as? Int
            ?? Int(DeckLinkAlphaKey.externalKey.rawValue)
        return DeckLinkAlphaKey(rawValue: Int32(raw)) ?? .externalKey
    }

    func keying(for device: DeckLinkHelperDevice) -> DeckLinkAlphaKey {
        guard role == .livestream, Self.alphaKeyOn else { return .off }
        switch Self.wantedKeyMode {
        case .externalKey where device.supportsExternalKeying: return .externalKey
        case .internalKey where device.supportsInternalKeying: return .internalKey
        default:
            if device.supportsExternalKeying { return .externalKey }
            if device.supportsInternalKeying { return .internalKey }
            return .off
        }
    }

    var deckLinkDevice: DeckLinkHelperDevice? {
        deckLinkBacking.flatMap { backing in
            catalog.devices.first { $0.persistentID == backing.devicePersistentID }
        }
    }

    /// After the alpha key settings change: each port re-keys at once.
    func applyKeying() {
        for backing in deckLinkBackings {
            guard let device = catalog.devices.first(where: { $0.persistentID == backing.devicePersistentID })
            else { continue }
            DeckLinkScreenOutputs.shared.setKeying(
                screenID: screen.id, devicePersistentID: device.persistentID,
                keying: keying(for: device), render: render)
        }
    }

    var alphaCaption: String {
        // Without a key the switcher can only luma key the picture, which
        // takes out black and leaves colors part see-through: worth saying
        // where the setting lives, since the editor shows the bar solid.
        guard deckLinkDevice != nil else {
            if ndiOn { return "NDI carries the livestream's transparency to the receiver." }
            return "A display carries no transparency: a switcher can only luma key it, which drops black and thins colors. Use NDI, or a DeckLink port with Alpha key on."
        }
        guard Self.alphaKeyOn else {
            return "Off: the switcher gets the full picture and can only luma key it, which drops black and thins colors."
        }
        switch deckLinkBacking?.keying {
        case .externalKey?: return "External: fill and key on separate connectors for the switcher's keyer."
        case .internalKey?: return "Internal: the card keys over the video at its SDI input."
        default: return "This DeckLink port can't key."
        }
    }
}

/// The arrangement's side of the same choice: which screen a display or a
/// DeckLink port carries.
@MainActor
enum ScreenRouting {
    static func role(on display: DisplayUUID, render: RenderContext) -> ShowScreen? {
        ShowScreen.allCases.first { role in
            guard let output = ScreenOutput(role, render: render) else { return false }
            return output.display == display || output.mirrorDisplay == display
        }
    }

    /// A display carries one screen. Giving it a screen moves that screen
    /// off wherever it was, and a screen the display had is left with no
    /// output; None just takes the display's screen off it (for the side
    /// TVs' second display, just that copy).
    static func assign(display: DisplayUUID, to role: ShowScreen?, render: RenderContext) {
        if let role {
            ScreenOutput(role, render: render)?.choose("display:\(display)")
        } else if let current = Self.role(on: display, render: render),
                  let output = ScreenOutput(current, render: render) {
            if output.mirrorDisplay == display {
                output.setMirror(nil)
            } else {
                output.choose("none")
            }
        }
    }

    static func roles(onDeckLink id: Int64, render: RenderContext) -> [ShowScreen] {
        ShowScreen.allCases.filter { role in
            ScreenOutput(role, render: render)?.deckLinkBackings.contains { $0.devicePersistentID == id } == true
        }
    }
}

/// Window › Screen Configuration, kept so its menu item and More › Screen
/// Setup… still work: the screens are set up in Settings › Screens now, so
/// this opens that and closes itself before it is seen.
struct OutputsWindow: View {
    let render: RenderContext?

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(HiddenWindow())
            .onAppear {
                SettingsRouter.shared.open(.screens)
                Task { @MainActor in
                    dismissWindow(id: "outputs")
                }
            }
    }
}

/// Keeps a window that only redirects from flashing on screen.
private struct HiddenWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.alphaValue = 0
            window?.isRestorable = false
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

