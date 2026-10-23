import CoreMIDI
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

@MainActor
final class ActionRouter {
    private unowned let model: AppModel
    private unowned let controls: ServiceControls
    private unowned let stream: StreamRouter

    private static let maxDepth = 4

    private var presentationFireDepth = 0

    init(
        model: AppModel, controls: ServiceControls, stream: StreamRouter,
        confidenceMonitor: ConfidenceMonitorController? = nil
    ) {
        self.model = model
        self.controls = controls
        self.stream = stream
        self.confidenceMonitor = confidenceMonitor
    }

    private let confidenceMonitor: ConfidenceMonitorController?

    var timerChoices: [(id: String, name: String)] {
        controls.timers.timers.map { ($0.id, $0.name) }
    }

    /// Makes a countdown from the Add Action menu so a slide can start a
    /// timer that doesn't exist yet. Returns its id for the new action.
    @discardableResult
    func addCountdownTimer(minutes: Int) -> String {
        controls.timers.addCountdown(name: "Countdown \(minutes):00", seconds: TimeInterval(minutes * 60))
    }

    var confidenceScreenChoices: [(id: String, name: String)] {
        (confidenceMonitor?.confidenceScreens ?? []).map { ($0.id.uuidString, $0.name) }
    }

    func noteLiveTheme(_ theme: Theme?, slide: Slide?) {
        stream.noteLiveTheme(theme, slide: slide)
    }

    /// A slide's livestream choice changed from its right-click menu.
    func noteStreamDesign(_ design: StreamDesign?, forSlides slideIDs: Set<String>) {
        stream.noteStreamDesign(design, forSlides: slideIDs)
    }

    /// Runs the presentation type's default actions when a presentation of
    /// that type goes live (not on every slide within it).
    func presentationDidGoLive(_ presentation: Presentation) {
        let actions = PresentationTypes.actions(
            for: presentation, rules: model.slideBuilding.presentationTypeRules)
        guard !actions.isEmpty else { return }
        DiagnosticsStore.shared.note(
            "actions.presentationType", detail: PresentationTypes.category(of: presentation) ?? "")
        execute(actions, depth: 0, visited: [])
    }

    func slideDidFire(_ slide: Slide, contextID: String?) {
        if let layoutID = slide.stageLayoutId, !layoutID.isEmpty {
            confidenceMonitor?.apply(layoutID: layoutID, toScreen: nil)
        }
        guard let actions = slide.actions, !actions.isEmpty else { return }
        let protected = SlideSceneBuilder.protectedLayers(for: slide, mediaLayer: mediaLayer)
        let effective = SlideSceneBuilder.fireActions(for: slide, protected: protected)
        if effective.count < actions.count {
            DiagnosticsStore.shared.note(
                "actions.clear.skippedOwnLayer", detail: slide.name)
        }
        guard !effective.isEmpty else { return }
        execute(
            effective, depth: 0, visited: [],
            protected: protected)
    }

    private func mediaLayer(_ mediaID: String) -> LayerKind? {
        model.media(mediaID).map { SlideSceneBuilder.layerKind(CueMedia.dropped(for: $0).layer) }
    }

    func mediaDidFire(_ item: MediaItem, on layer: LayerKind) {
        guard let actions = item.actions, !actions.isEmpty else { return }
        let effective = SlideSceneBuilder.fireActions(forMedia: item, on: layer)
        if effective.count < actions.count {
            DiagnosticsStore.shared.note(
                "actions.clear.skippedOwnLayer", detail: item.name)
        }
        guard !effective.isEmpty else { return }
        execute(
            effective, depth: 0, visited: [],
            protected: [layer])
    }

    func fire(comboID: String) {
        guard let combo = try? model.actionCombo(comboID) else {
            DiagnosticsStore.shared.note("actions.combo.missing", detail: comboID)
            return
        }
        model.markUsed(comboID)
        execute(combo.actions, depth: 1, visited: [comboID])
    }

    func execute(_ actions: [SlideAction]) {
        execute(actions, depth: 0, visited: [])
    }

    private var startupRan = false

    func runStartupCombos() async {
        guard !startupRan else { return }
        startupRan = true
        try? await Task.sleep(for: .seconds(2))

        await model.resident.ready([.actionCombo])
        let startup = model.resident.actionCombos.values
            .filter { $0.runOnStartup == true }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        for combo in startup {
            DiagnosticsStore.shared.note("actions.startup", detail: combo.name)
            execute(combo.actions, depth: 1, visited: [combo.id])
        }
    }

    private func execute(
        _ actions: [SlideAction], depth: Int, visited: Set<String>,
        protected: Set<LayerKind> = []
    ) {
        let schedule = SlideSceneBuilder.delaySchedule(actions)
        for action in schedule.immediate {
            perform(
                action, depth: depth, visited: visited,
                protected: protected)
        }
        for batch in schedule.delayed {
            scheduleDelayed(
                batch.actions, after: batch.delay, depth: depth, visited: visited)
        }
    }

    private var pendingDelayed: [Int: Task<Void, Never>] = [:]
    private var pendingTokensByActionID: [String: Int] = [:]
    private var nextDelayToken = 0

    private func scheduleDelayed(
        _ batch: [SlideAction], after delay: Double, depth: Int, visited: Set<String>
    ) {
        for action in batch {
            if let token = pendingTokensByActionID[action.id] {
                pendingDelayed[token]?.cancel()
                pendingDelayed[token] = nil
            }
        }
        nextDelayToken += 1
        let token = nextDelayToken
        for action in batch { pendingTokensByActionID[action.id] = token }

        let ripe = batch.map { action in
            var step = action
            step.delaySeconds = nil
            return step
        }
        DiagnosticsStore.shared.note(
            "actions.delayed.scheduled",
            detail: "\(batch.count) step(s) in \(delay)s")
        pendingDelayed[token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.forgetDelayed(token: token)
            DiagnosticsStore.shared.note(
                "actions.delayed.fired",
                detail: ripe.map(\.kind.rawValue).joined(separator: ","))
            self.execute(ripe, depth: depth, visited: visited)
        }
    }

    private func forgetDelayed(token: Int) {
        pendingDelayed[token] = nil
        for (id, entry) in pendingTokensByActionID where entry == token {
            pendingTokensByActionID[id] = nil
        }
    }

    func cancelPendingDelayedActions() {
        guard !pendingDelayed.isEmpty else { return }
        DiagnosticsStore.shared.note(
            "actions.delayed.cancelled", detail: "\(pendingDelayed.count) batch(es)")
        for task in pendingDelayed.values { task.cancel() }
        pendingDelayed = [:]
        pendingTokensByActionID = [:]
    }

    private func perform(
        _ action: SlideAction, depth: Int, visited: Set<String>,
        protected: Set<LayerKind> = []
    ) {
        performNow(action, depth: depth, visited: visited, protected: protected)
    }

    private func performNow(
        _ action: SlideAction, depth: Int, visited: Set<String>,
        protected: Set<LayerKind>
    ) {
        switch action.kind {
        case .clearLayer:
            guard let layer = action.layer.flatMap(LayerKind.init(rawValue:)) else {
                return miss(action, "layer")
            }

            if protected.contains(layer) {
                DiagnosticsStore.shared.note(
                    "actions.clear.skippedOwnLayer", detail: layer.rawValue)
                return
            }
            controls.clear(layer: layer)
        case .clearAll:
            if !protected.isEmpty {
                DiagnosticsStore.shared.note(
                    "actions.clear.allScoped",
                    detail: protected.map(\.rawValue).sorted().joined(separator: ","))
            }
            controls.clearAll(protecting: protected, cancelsPendingActions: false)
        case .fireMedia:
            guard let mediaID = action.mediaId,
                  let item = model.media(mediaID)
            else { return miss(action, "mediaId") }
            controls.fire(mediaItem: item)
        case .fireAlert:
            guard let alertID = action.alertId,
                  let preset = try? model.alertPreset(alertID)
            else { return miss(action, "alertId") }
            controls.fire(alertPreset: preset)
        case .dismissAlert:
            controls.dismissAlert()
        case .timerStart:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.start(id: timerID)
        case .timerPause:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.pause(id: timerID)
        case .timerReset:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.reset(id: timerID)
        case .timerConfigure:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.configure(
                id: timerID,
                mode: action.timerMode.map { mode in
                    switch mode {
                    case .countdown: .countdown
                    case .countdownToTime: .countdownToTime
                    case .countUp: .countUp
                    }
                },
                durationSeconds: action.timerDurationSeconds,
                hour: action.timerHour, minute: action.timerMinute
            )
        case .midiOut where action.midiDeviceId == LightkeyLink.deviceID:
            LightkeyLink.shared.send(
                kind: action.midiKind ?? .noteOn,
                channel: action.midiChannel ?? LightkeyLink.shared.channel,
                number: action.midiNumber ?? 0,
                value: action.midiValue ?? 127)
        case .midiOut:
            switch MIDIOutTarget.resolve(
                deviceId: action.midiDeviceId, items: MIDIDeviceInventory.shared.items
            ) {
            case .settingsSelection:
                MIDIOutService.shared.send(
                    kind: action.midiKind ?? .noteOn,
                    channel: action.midiChannel ?? 1,
                    number: action.midiNumber ?? 0,
                    value: action.midiValue ?? 127
                )
            case .device(let uid):
                MIDIOutService.shared.send(
                    kind: action.midiKind ?? .noteOn,
                    channel: action.midiChannel ?? 1,
                    number: action.midiNumber ?? 0,
                    value: action.midiValue ?? 127,
                    toDestination: uid
                )
            case .skip(let reason):
                DiagnosticsStore.shared.note(
                    "actions.skipped", detail: "midiOut \(reason)")
            }
        case .fireCombo:
            guard let comboID = action.comboId, !comboID.isEmpty else {
                return miss(action, "comboId")
            }
            guard depth < Self.maxDepth, !visited.contains(comboID) else {
                DiagnosticsStore.shared.note(
                    "actions.combo.cycle", detail: "\(comboID) depth=\(depth)")
                return
            }
            guard let combo = try? model.actionCombo(comboID) else {
                return miss(action, "comboId")
            }
            execute(
                combo.actions, depth: depth + 1, visited: visited.union([comboID]),
                protected: protected)
        case .firePresentation:
            guard let presentationID = action.presentationId else {
                return miss(action, "presentationId")
            }

            guard let presentation = model.presentation(presentationID) else {
                return miss(action, model.presentationExists(presentationID)
                    ? "presentation still decoding" : "presentationId")
            }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: nil)
            let index = action.slideIndex ?? 0
            guard slides.indices.contains(index) else {
                return miss(action, "slideIndex")
            }
            guard presentationFireDepth < Self.maxDepth else {
                DiagnosticsStore.shared.note(
                    "actions.presentation.cycle",
                    detail: "\(presentationID) depth=\(presentationFireDepth)")
                return
            }
            presentationFireDepth += 1
            defer { presentationFireDepth -= 1 }
            // A scheduled click in a given plan brings that plan up first.
            if let plan = action.serviceId, !plan.isEmpty, model.currentServiceID != plan {
                model.currentServiceID = plan
            }
            controls.fire(slide: slides[index], in: presentation)
        case .setStreamMode:
            if let mode = action.streamMode.flatMap(ShowSetup.StreamMode.init(rawValue:)) {
                ShowSetup.shared.streamMode = mode
            }
        case .setStageMode:
            if let mode = action.stageMode.flatMap(ShowSetup.StageMode.init(rawValue:)) {
                ShowSetup.shared.stageMode = mode
            }
        case .listenStart:
            // The first slide of the message turns on the sermon microphone.
            if !(LiveAssist.shared.listening && LiveAssist.shared.mode == .sermon) {
                Task { await LiveAssist.shared.startSermon() }
            }
        case .listenStop:
            if LiveAssist.shared.listening { LiveAssist.shared.stop() }
        case .fireServiceItem:
            // A scheduled countdown: bring the plan up, then play its item
            // in the plan, so its end moves on to the next item.
            guard let planID = action.serviceId, let itemID = action.serviceItemId,
                  let item = model.resident.services.value(planID)?.items.first(where: { $0.id == itemID })
            else { return miss(action, "serviceItemId") }
            if model.currentServiceID != planID { model.currentServiceID = planID }
            if case .unresolvable = controls.fireServiceItem(item) { return miss(action, "serviceItem media") }
        case .setConfidenceLayout:
            guard let confidenceMonitor else { return miss(action, "confidenceMonitor") }

            confidenceMonitor.apply(
                layoutID: action.confidenceLayoutId,
                toScreen: action.confidenceScreenId.flatMap(UUID.init(uuidString:))
            )
        case .fireLiveInput:
            let layer = action.layer.flatMap(LayerKind.init(rawValue:)) ?? .videoInput
            if let itemID = action.liveInputId, !itemID.isEmpty {

                controls.fire(liveInputId: itemID, on: layer)
            } else if let sourceID = action.inputSourceId, !sourceID.isEmpty {

                controls.fire(
                    liveInputKind: action.inputSourceKind ?? .camera,
                    sourceId: sourceID,
                    on: layer
                )
            } else {
                return miss(action, "liveInputId")
            }
        case .clearAudio, .clearSignage, .switchOutputPreset, .captureStart, .captureStop,
             .fireOverlay, .dismissOverlay, .setSignage, .setScreenSource,
             .enableAudioInput, .disableAudioInput, .fireAudio, .fireAudioPlaylist:
            // Music, capture, Looks, overlays and signage were taken out of
            // the app. Old slides and macros may still carry these; they do
            // nothing now.
            DiagnosticsStore.shared.note("actions.retired", detail: action.kind.rawValue)
        }
    }

    private func miss(_ action: SlideAction, _ field: String) {
        DiagnosticsStore.shared.note(
            "actions.skipped", detail: "\(action.kind.rawValue) missing \(field)")
    }
}

final class MIDIOutService: @unchecked Sendable {
    static let shared = MIDIOutService()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// A virtual source named "Screens" that every message is also sent from,
    /// so Lightkey (or any MIDI app) can listen to Screens directly — no IAC
    /// bus or Audio MIDI Setup needed.
    private var virtualSource = MIDIEndpointRef()
    private var ready = false

    private var targetUIDs: Set<Int32>?
    private var targetsLoaded = false
    private let lock = NSLock()

    private init() {}

    func setTargets(_ uids: Set<Int32>?) {
        lock.lock()
        targetUIDs = uids
        targetsLoaded = true
        lock.unlock()
    }

    /// Creates the client, output port and the "Screens" virtual source.
    /// Called at launch so the source is visible to other apps before the
    /// first message.
    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        prepareLocked()
    }

    @discardableResult
    private func prepareLocked() -> Bool {
        if ready { return true }
        guard MIDIClientCreate("Screens" as CFString, nil, nil, &client) == noErr,
              MIDIOutputPortCreate(client, "Screens Out" as CFString, &port) == noErr
        else { return false }
        if MIDISourceCreate(client, "Screens" as CFString, &virtualSource) != noErr {
            virtualSource = 0
        }
        ready = true
        return true
    }

    static func bytes(kind: MIDIMessageKind, channel: Int, number: Int, value: Int) -> [UInt8] {
        let channelBits = UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        switch kind {
        case .noteOn: return [0x90 | channelBits, UInt8(number & 0x7F), UInt8(value & 0x7F)]
        case .noteOff: return [0x80 | channelBits, UInt8(number & 0x7F), UInt8(value & 0x7F)]
        case .controlChange: return [0xB0 | channelBits, UInt8(number & 0x7F), UInt8(value & 0x7F)]
        case .programChange: return [0xC0 | channelBits, UInt8(number & 0x7F)]
        }
    }

    /// To Lightkey: the "Screens" virtual source (Lightkey on this Mac) and,
    /// when given, a network MIDI session (Lightkey on another Mac).
    func sendToLightkey(
        kind: MIDIMessageKind, channel: Int, number: Int, value: Int, network: MIDIEndpointRef?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard prepareLocked() else { return }
        let data = Self.bytes(kind: kind, channel: channel, number: number, value: value)
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, data.count, data)
        if virtualSource != 0 { MIDIReceived(virtualSource, &packetList) }
        if let network, network != 0 { MIDISend(port, network, &packetList) }
    }

    func send(
        kind: MIDIMessageKind, channel: Int, number: Int, value: Int,
        toDestination explicitUID: Int32? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard prepareLocked() else { return }
        if !targetsLoaded {

            targetUIDs = MIDIDeviceStore.loadCachedTargets()
            targetsLoaded = true
        }
        let data = Self.bytes(kind: kind, channel: channel, number: number, value: value)
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(
            &packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, data.count, data)
        if explicitUID == nil, virtualSource != 0 {
            MIDIReceived(virtualSource, &packetList)
        }
        if explicitUID == nil, let targets = targetUIDs, targets.isEmpty { return }
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            if explicitUID != nil || targetUIDs != nil {
                var uid: Int32 = 0
                guard MIDIObjectGetIntegerProperty(
                    destination, kMIDIPropertyUniqueID, &uid) == noErr
                else { continue }
                if let explicitUID {
                    guard uid == explicitUID else { continue }
                } else if let targets = targetUIDs {
                    guard targets.contains(uid) else { continue }
                }
            }
            MIDISend(port, destination, &packetList)
        }
    }
}

extension MIDIMessageKind {
    var displayName: String {
        switch self {
        case .noteOn: "Note On"
        case .noteOff: "Note Off"
        case .controlChange: "Control Change"
        case .programChange: "Program Change"
        }
    }
}

private struct ActionRouterKey: EnvironmentKey {
    static let defaultValue: ActionRouter? = nil
}

extension EnvironmentValues {
    var actionRouter: ActionRouter? {
        get { self[ActionRouterKey.self] }
        set { self[ActionRouterKey.self] = newValue }
    }
}
