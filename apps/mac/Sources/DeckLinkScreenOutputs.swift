import Foundation
import Observation
import OutputEngine

enum DeckLinkAlphaKey: Int32, Codable, CaseIterable {
    case off = 0
    case internalKey = 1
    case externalKey = 2

    var label: String {
        switch self {
        case .off: "Off"
        case .internalKey: "Internal"
        case .externalKey: "External"
        }
    }
}

@MainActor
@Observable
final class DeckLinkScreenOutputs {
    static let shared = DeckLinkScreenOutputs()

    struct Backing: Codable, Equatable {
        var devicePersistentID: Int64
        var deviceName: String
        var keying: DeckLinkAlphaKey

        var mode: DeckLinkHelperDisplayMode?
    }

    private(set) var controllers: [Int64: DeckLinkOutputController] = [:]
    /// The ports each screen goes out of. One screen can be on several
    /// (the Audience on ports 1 and 4 of an 8K Pro, one per projector), and
    /// one port can carry several screens packed into its frame.
    private(set) var backings: [UUID: [Backing]] = [:]
    /// Saved as a list of ports per screen. The old key held one port per
    /// screen: giving the Audience a second port replaced the first in what
    /// was saved while the first went on sending, so after a quit only the
    /// last port chosen came back. It is still read when the new one is
    /// missing, so the ports set before this change are kept.
    private static let defaultsKey = "decklink.screenPorts"
    private static let legacyDefaultsKey = "decklink.screenBackings"
    /// Nothing is saved until the saved outputs are back. NDI restores
    /// first, and switching a screen to NDI switches its DeckLink port off,
    /// which used to save the empty list over the ports not yet restored,
    /// so the Audience 8K was gone after every relaunch.
    private var restored = false

    /// Kept from the last enable or restore so the catalog's checks can
    /// start a port again without a screen change to hand one in.
    private weak var render: RenderContext?

    /// The ports the catalog saw last time, to tell when one appears.
    private var knownDevices: Set<Int64> = []

    private init() {}

    private func portControllers(for screenID: UUID) -> [DeckLinkOutputController] {
        (backings[screenID] ?? []).compactMap { controllers[$0.devicePersistentID] }
    }

    private func backing(_ screenID: UUID, on devicePersistentID: Int64) -> Backing? {
        backings[screenID]?.first { $0.devicePersistentID == devicePersistentID }
    }

    func members(onDevice devicePersistentID: Int64) -> [UUID] {
        backings.filter { $0.value.contains { $0.devicePersistentID == devicePersistentID } }
            .keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// The screen's state across its ports. The least healthy one wins, so
    /// a port that has stopped isn't hidden by another that is sending.
    func status(for screenID: UUID) -> DeckLinkOutputController.Status? {
        let statuses = portControllers(for: screenID).map(\.status)
        guard !statuses.isEmpty else { return nil }
        func rank(_ status: DeckLinkOutputController.Status) -> Int {
            switch status {
            case .failed: 4
            case .interrupted: 3
            case .starting: 2
            case .sending: 1
            case .idle: 0
            }
        }
        return statuses.max { rank($0) < rank($1) }
    }

    func isCarrying(_ screenID: UUID) -> Bool {
        portControllers(for: screenID).contains(where: \.isActive)
    }

    func wireDetail(for screenID: UUID) -> String {
        portControllers(for: screenID).map(\.wireDetail).first { !$0.isEmpty } ?? ""
    }

    /// The screen's first port, for the settings that show one: its keying
    /// and what the Output menu names.
    func backing(for screenID: UUID) -> Backing? {
        backings[screenID]?.first
    }

    /// Every port the screen is on, in the order they were added.
    func backingList(for screenID: UUID) -> [Backing] {
        backings[screenID] ?? []
    }

    /// Puts the screen on a port. `adding` keeps the screen's other ports
    /// (a second projector); otherwise this port replaces them, and the
    /// ports it leaves stop or go on with their other screens. `joining`
    /// keeps the port's other screens; otherwise this screen replaces them.
    func enable(
        screenID: UUID, device: DeckLinkHelperDevice, keying: DeckLinkAlphaKey,
        mode: DeckLinkHelperDisplayMode? = nil, joining: Bool = false, adding: Bool = false,
        render: RenderContext
    ) {
        guard render.outputs.sliceInfo(for: screenID) != nil else {
            DiagnosticsStore.shared.note(
                "decklink.enable", detail: "\(device.name): screen \(screenID) not found — skipped")
            return
        }
        self.render = render
        var left: Set<Int64> = []
        var ports = backings[screenID] ?? []
        if adding {
            ports.removeAll { $0.devicePersistentID == device.persistentID }
        } else {
            left = Set(ports.map(\.devicePersistentID))
            ports = []
        }

        NDIScreenOutputs.shared.disable(screenID: screenID)
        if !joining {
            for otherID in members(onDevice: device.persistentID) where otherID != screenID {
                backings[otherID]?.removeAll { $0.devicePersistentID == device.persistentID }
                if backings[otherID]?.isEmpty == true { backings.removeValue(forKey: otherID) }
            }
        }
        render.outputs.assignPlaceholderDevice(placeholderID: screenID, displayUUID: nil)
        let incumbent = members(onDevice: device.persistentID)
            .filter { $0 != screenID }
            .compactMap { backing($0, on: device.persistentID) }.first
        ports.append(Backing(
            devicePersistentID: device.persistentID,
            deviceName: device.name,
            keying: joining ? incumbent?.keying ?? keying : keying,
            mode: joining ? incumbent?.mode ?? mode : mode))
        backings[screenID] = ports
        left.remove(device.persistentID)
        for port in left { rebuildCarry(devicePersistentID: port, render: render) }
        rebuildCarry(devicePersistentID: device.persistentID, render: render)
        persist()
    }

    private func rebuildCarry(devicePersistentID: Int64, render: RenderContext) {
        let memberIDs = members(onDevice: devicePersistentID)
        guard let firstID = memberIDs.first, let backing = self.backing(firstID, on: devicePersistentID) else {
            controllers[devicePersistentID]?.stop()
            controllers.removeValue(forKey: devicePersistentID)
            return
        }
        let mode = backing.mode
        let controller = controllers[devicePersistentID]
            ?? DeckLinkOutputController(render: render)
        controllers[devicePersistentID] = controller
        let infos = memberIDs.compactMap { id -> (id: UUID, screenID: UUID, sourceRect: CGRect, width: Int, height: Int, name: String?)? in
            render.outputs.sliceInfo(for: id).map { (id, $0.screenID, $0.sourceRect, $0.width, $0.height, $0.name) }
        }
        guard let first = infos.first else { return }
        let firstScreen = render.outputs.placeholderScreens
            .first { $0.id == first.screenID }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        if infos.count == 1 {
            controller.start(
                targetID: first.id.uuidString,
                targetName: first.name.map { "\(firstScreen?.name ?? "Screen") — \($0)" }
                    ?? firstScreen?.name ?? "Screen",
                devicePersistentID: devicePersistentID,
                deviceName: backing.deviceName,
                keying: backing.keying,
                width: mode?.width
                    ?? render.outputs.placement(forSlice: first.id)?.frameWidth ?? first.width,
                height: mode?.height
                    ?? render.outputs.placement(forSlice: first.id)?.frameHeight ?? first.height,
                frameRate: mode?.mirrorFramesPerSecond ?? firstScreen?.framesPerSecond ?? 30,
                modeID: mode?.modeID ?? 0,
                sourceRect: first.sourceRect == full ? nil : first.sourceRect,
                placement: render.outputs.placement(forSlice: first.id)?.unitRect
            )
            return
        }
        let layers = infos.map { info in
            OutputMirror.CompositeLayer(
                provider: render.outputs.previewProvider(for: info.screenID.uuidString),
                sourceRect: info.sourceRect == full ? nil : info.sourceRect,
                placement: render.outputs.placement(forSlice: info.id)?.unitRect,
                adjustments: render.outputs.adjustmentsProvider(for: info.id.uuidString),
                mask: render.outputs.maskProvider(for: info.id.uuidString)
            )
        }
        let frame = render.outputs.placement(forSlice: first.id)
        controller.start(
            targetID: first.id.uuidString,
            targetName: "\(backing.deviceName) — packed frame (\(infos.count))",
            devicePersistentID: devicePersistentID,
            deviceName: backing.deviceName,
            keying: backing.keying,
            width: mode?.width ?? frame?.frameWidth ?? 1920,
            height: mode?.height ?? frame?.frameHeight ?? 1080,
            frameRate: mode?.mirrorFramesPerSecond ?? firstScreen?.framesPerSecond ?? 30,
            modeID: mode?.modeID ?? 0,
            composite: layers
        )
    }

    /// One port's keying. Each port is keyed for itself, since two ports
    /// on different cards may not key the same way.
    func setKeying(
        screenID: UUID, devicePersistentID: Int64, keying: DeckLinkAlphaKey, render: RenderContext
    ) {
        guard backing(screenID, on: devicePersistentID) != nil else { return }
        for member in members(onDevice: devicePersistentID) {
            update(member, on: devicePersistentID) { $0.keying = keying }
        }
        rebuildCarry(devicePersistentID: devicePersistentID, render: render)
        persist()
    }

    func setMode(
        screenID: UUID, mode: DeckLinkHelperDisplayMode?, render: RenderContext
    ) {
        for port in backingList(for: screenID).map(\.devicePersistentID) {
            for member in members(onDevice: port) {
                update(member, on: port) { $0.mode = mode }
            }
            rebuildCarry(devicePersistentID: port, render: render)
        }
        persist()
    }

    private func update(_ screenID: UUID, on devicePersistentID: Int64, _ change: (inout Backing) -> Void) {
        guard let index = backings[screenID]?.firstIndex(where: { $0.devicePersistentID == devicePersistentID })
        else { return }
        change(&backings[screenID]![index])
    }

    func refreshCarry(for screenID: UUID, render: RenderContext) {
        for port in backingList(for: screenID).map(\.devicePersistentID) {
            rebuildCarry(devicePersistentID: port, render: render)
        }
    }

    private func device(for backing: Backing) -> DeckLinkHelperDevice {
        DeckLinkHelperDevice(
            name: backing.deviceName,
            persistentID: backing.devicePersistentID,
            supportsPlayback: true,
            supportsInternalKeying: true,
            supportsExternalKeying: true)
    }

    /// Takes the screen off every port it's on.
    func disable(screenID: UUID, render: RenderContext? = nil) {
        // A screen with no port: nothing changed, nothing to save.
        guard let ports = backings.removeValue(forKey: screenID) else { return }
        for port in ports { release(port.devicePersistentID, render: render) }
        persist()
    }

    /// Takes the screen off one port and leaves its others sending.
    func disable(screenID: UUID, devicePersistentID: Int64, render: RenderContext) {
        guard backing(screenID, on: devicePersistentID) != nil else { return }
        backings[screenID]?.removeAll { $0.devicePersistentID == devicePersistentID }
        if backings[screenID]?.isEmpty == true { backings.removeValue(forKey: screenID) }
        release(devicePersistentID, render: render)
        persist()
    }

    /// A port that just lost a screen: it carries the ones left, or stops.
    private func release(_ devicePersistentID: Int64, render: RenderContext?) {
        if let render {
            rebuildCarry(devicePersistentID: devicePersistentID, render: render)
        } else if members(onDevice: devicePersistentID).isEmpty {
            controllers[devicePersistentID]?.stop()
            controllers.removeValue(forKey: devicePersistentID)
        }
    }

    func restore(render: RenderContext) {
        defer { restored = true }
        self.render = render
        let defaults = UserDefaults.standard
        var stored: [String: [Backing]] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let lists = try? JSONDecoder().decode([String: [Backing]].self, from: data) {
            stored = lists
        } else if let data = defaults.data(forKey: Self.legacyDefaultsKey),
                  let single = try? JSONDecoder().decode([String: Backing].self, from: data) {
            stored = single.mapValues { [$0] }
        }
        guard !stored.isEmpty else { return }
        DiagnosticsStore.shared.note(
            "decklink.restore",
            detail: stored.values.flatMap { $0 }.map { "\($0.deviceName) (\($0.devicePersistentID))" }
                .sorted().joined(separator: ", "))
        // The port opens straight away, without waiting for the catalog:
        // the helper looks the device up itself, and each port keeps trying
        // until it sends, so a card the driver hasn't finished bringing up
        // at launch comes up on a later try.
        for (raw, ports) in stored {
            guard let id = UUID(uuidString: raw) else { continue }
            for backing in ports {
                enable(
                    screenID: id, device: device(for: backing),
                    keying: backing.keying, mode: backing.mode, joining: true, adding: true,
                    render: render)
            }
        }
    }

    /// The catalog's answer, every few seconds. A port waiting to retry
    /// whose device has just appeared tries now rather than at the end of
    /// its wait, and a port with screens on it but nothing running (its
    /// start was skipped) is started again. A port that is sending is left
    /// alone.
    func catalogFound(_ devices: [DeckLinkHelperDevice]) {
        let found = Set(devices.map(\.persistentID))
        let appeared = found.subtracting(knownDevices)
        knownDevices = found
        let wanted = Set(backings.values.flatMap { $0 }.map(\.devicePersistentID))
        for device in wanted {
            if let controller = controllers[device], controller.isActive {
                if appeared.contains(device) { controller.retrySoon() }
            } else if let render,
                members(onDevice: device).contains(where: {
                    render.outputs.sliceInfo(for: $0) != nil
                }) {
                DiagnosticsStore.shared.note(
                    "decklink.restore", detail: "port \(device) assigned but not running — starting it")
                rebuildCarry(devicePersistentID: device, render: render)
            }
        }
    }

    private func persist() {
        guard restored else { return }
        let stored = Dictionary(
            uniqueKeysWithValues: backings.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(
            try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class DeckLinkDeviceCatalog {
    static let shared = DeckLinkDeviceCatalog()

    private(set) var devices: [DeckLinkHelperDevice] = []
    /// Every port the driver reports, output-capable or not — for diagnosis.
    private(set) var allDevices: [DeckLinkHelperDevice] = []
    private(set) var hasFetched = false

    private(set) var runtimeVersionLabel = ""
    private(set) var runtimeTooOld = false
    private var modesFetchInFlight: Set<Int64> = []

    private(set) var displayModes: [Int64: [DeckLinkHelperDisplayMode]] = [:]

    /// The output ports the last look found, so one that comes back is
    /// asked for its modes again.
    @ObservationIgnored private var portsSeen: Set<Int64> = []

    private init() {}

    /// Asks the helper which ports there are. The background watch (every
    /// 8 s, DeckLinkAutoSetup) asks only new ports for their modes;
    /// Settings passes `allModes` so a port remapped in Desktop Video Setup
    /// shows its new modes while someone is looking.
    func refresh(allModes: Bool = false) {
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            connection.invalidate()
        }) as? DeckLinkHelperProtocol else {
            connection.invalidate()
            return
        }

        nonisolated(unsafe) let replyConnection = connection
        proxy.runtimeVersion { @Sendable version, tooOld in
            Task { @MainActor [weak self] in
                self?.runtimeVersionLabel = version
                self?.runtimeTooOld = tooOld
            }
        }
        proxy.listDevices { @Sendable data in
            let devices = (try? JSONDecoder().decode(
                [DeckLinkHelperDevice].self, from: data)) ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                // This runs every 8 seconds all day. Setting an observed
                // property re-runs every view that reads it even when the
                // value is the same, so only a real change is set.
                let playback = devices.filter(\.supportsPlayback)
                if self.allDevices != devices { self.allDevices = devices }
                if self.devices != playback { self.devices = playback }
                if !self.hasFetched { self.hasFetched = true }
                DeckLinkScreenOutputs.shared.catalogFound(playback)
                replyConnection.invalidate()

                // A port's modes don't change while it stays plugged in, and
                // asking walks the driver in the same helper that feeds the
                // outputs: ask once per port, again only after it has gone
                // and come back (or when Settings asks with refreshAllModes).
                let present = Set(playback.map(\.persistentID))
                let returned = present.subtracting(self.portsSeen)
                self.portsSeen = present
                for device in playback
                where allModes || returned.contains(device.persistentID) || self.displayModes[device.persistentID] == nil {
                    self.refreshModes(devicePersistentID: device.persistentID)
                }
            }
        }
    }

    func refreshModes(devicePersistentID: Int64) {

        guard !modesFetchInFlight.contains(devicePersistentID) else { return }
        modesFetchInFlight.insert(devicePersistentID)
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            connection.invalidate()
            // No reply is coming (the helper crashed, or was killed when a
            // port wedged): the next catalog refresh has to be free to ask
            // again, or this port's modes stay missing until a relaunch.
            Task { @MainActor [weak self] in
                self?.modesFetchInFlight.remove(devicePersistentID)
            }
        }) as? DeckLinkHelperProtocol else {
            connection.invalidate()
            modesFetchInFlight.remove(devicePersistentID)
            return
        }
        nonisolated(unsafe) let replyConnection = connection
        proxy.listDisplayModes(devicePersistentID: devicePersistentID) { @Sendable data in
            let modes = (try? JSONDecoder().decode(
                [DeckLinkHelperDisplayMode].self, from: data)) ?? []

            Task { @MainActor [weak self] in
                // Written down when a port's modes change, not on every look:
                // the same line every 8 s for each port was 3,600 lines an
                // hour in the booth's breadcrumbs.
                if self?.displayModes[devicePersistentID] != modes {
                    DiagnosticsStore.shared.note(
                        "decklink.modes",
                        detail: "device \(devicePersistentID): \(modes.count) modes")
                    self?.displayModes[devicePersistentID] = modes
                }
                self?.modesFetchInFlight.remove(devicePersistentID)
                replyConnection.invalidate()
            }
        }
    }
}
