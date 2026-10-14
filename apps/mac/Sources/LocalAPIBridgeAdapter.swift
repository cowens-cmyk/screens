import Foundation
import LocalAPI
import PresenterCore
import RenderEngine
import SlideScene

@MainActor
final class AppAPIBridge: LocalAPIBridge {
    private let appModel: AppModel
    private let controls: ServiceControls
    private let render: RenderContext

    private weak var scheduler: SchedulerController?

    init(
        appModel: AppModel, controls: ServiceControls,
        render: RenderContext,
        scheduler: SchedulerController?
    ) {
        self.appModel = appModel
        self.controls = controls
        self.render = render
        self.scheduler = scheduler
    }

    private static let idCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
    )

    private static func validatedID(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy(Self.idCharacters.contains),
              !id.contains("..")
        else {
            throw APIError.badRequest("Invalid document id.")
        }
        return id
    }

    private static func documentKind(_ kind: APIDocumentKind) -> DocumentKind {
        switch kind {
        case .presentations: .presentation
        case .services: .service
        case .themes: .theme
        case .media: .media
        case .playlists: .playlist
        case .alertPresets: .alertPreset
        case .actionCombos: .actionCombo
        case .scheduleTriggers: .scheduleTrigger
        case .confidenceLayouts: .confidenceLayout
        }
    }

    func librarySummary() throws -> APILibrarySummary {
        var counts: [String: Int] = [:]
        for kind in APIDocumentKind.allCases {
            counts[kind.rawValue] = appModel.entries(of: Self.documentKind(kind)).count
        }
        return APILibrarySummary(counts: counts)
    }

    func libraryEntries(kind: APIDocumentKind) throws -> [APILibraryEntry] {
        let entries = appModel.entries(of: Self.documentKind(kind))
        return entries.map { entry in
            APILibraryEntry(
                id: entry.id, name: entry.name, kind: kind.rawValue,
                folder: entry.subkind.isEmpty ? nil : entry.subkind,
                updatedAt: entry.updatedAt
            )
        }
    }

    func documentJSON(kind: APIDocumentKind, id: String) async throws -> Data {
        switch Self.documentKind(kind) {
        case .presentation: try await encode(Presentation.self, id: id)
        case .service: try await encode(Service.self, id: id)
        case .theme: try await encode(Theme.self, id: id)
        case .media: try await encode(MediaItem.self, id: id)
        case .playlist: try await encode(Playlist.self, id: id)
        case .alertPreset: try await encode(AlertPreset.self, id: id)
        case .actionCombo: try await encode(ActionCombo.self, id: id)
        case .scheduleTrigger: try await encode(ScheduleTrigger.self, id: id)
        case .confidenceLayout: try await encode(ConfidenceLayout.self, id: id)

        case .audio, .overlay, .outputPreset, .streamRecordPreset,
            .midiDevice, .streamDestination, .schedulerBoard, .controlBoard, .groupPalette,
            .signageBoard, .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .note, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: throw APIError.notFound("Unknown document kind.")
        }
    }

    private func encode<E: DocumentEntity>(_ type: E.Type, id: String) async throws -> Data {
        let safeID = try Self.validatedID(id)
        await appModel.client.settled()
        guard let value = try? await appModel.client.loadValue(type, id: safeID) else {
            throw APIError.notFound("No document with id '\(id)'.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func showStatus() -> APIShowStatus {
        let state = controls.state
        let service = appModel.currentServiceID.flatMap { try? appModel.service($0) }
        var liveSlide: APIShowStatus.LiveSlide?
        if let live = state.liveSlide {

            var serviceItemId: String?
            if let contextID = controls.liveContextID,
               let service, service.items.contains(where: { $0.id == contextID }) {
                serviceItemId = contextID
            }
            let text = ConfidenceSceneBuilder.slideText(for: live.slide, in: live.presentation).body
            liveSlide = APIShowStatus.LiveSlide(
                presentationId: live.presentation?.id ?? "",
                presentationName: live.presentation?.name,
                slideId: live.slide.id,
                slideIndex: controls.liveOccurrence,
                slideName: live.slide.name.isEmpty ? nil : live.slide.name,
                serviceItemId: serviceItemId,
                occurrence: controls.liveOccurrence,
                stepIndex: controls.slideAnimationStep?.consumed,
                stepCount: controls.slideAnimationStep?.total,
                text: text.isEmpty ? nil : text,
                slideCount: controls.slidePosition?.total
            )
        }
        var mediaLayers: [String: APIShowStatus.LayerContent] = [:]
        for (layer, cue) in state.liveMedia {
            mediaLayers[layer.rawValue] = APIShowStatus.LayerContent(
                mediaId: cue.mediaId,
                mediaName: appModel.entry(cue.mediaId)?.name,
                loops: cue.loops
            )
        }
        return APIShowStatus(
            liveSlide: liveSlide,
            nextSlideText: controls.nextSlideText,
            mediaLayers: mediaLayers,
            overlays: state.liveOverlays.map {
                APIShowStatus.Overlay(id: $0.id, name: $0.name, layer: $0.layer)
            },
            alert: state.liveAlert.map {
                APIShowStatus.Alert(
                    id: $0.id, message: $0.message,
                    behavior: $0.behavior.rawValue, target: $0.target.rawValue,
                    layer: $0.layer?.rawValue
                )
            },
            currentServiceId: appModel.currentServiceID,
            service: service.map {
                APIShowStatus.ServiceRef(id: $0.id, name: $0.name)
            },
            nextSlide: APIShowStatus.NextSlide(text: controls.nextSlideText),
            position: APIShowStatus.Position(
                currentItemName: controls.currentItemName, nextItemName: controls.nextItemName)
        )
    }

    func timers() -> [APITimerStatus] {
        timers(at: Date())
    }

    func timersDocument() -> APITimersDocument {
        _ = controls.media.rows.count
        let now = Date()
        let timers = controls.timers.timers.map { timer in
            timerStatus(timer, at: timer.isLive ? (timer.runningSince ?? timer.armedAt ?? now) : now)
        }
        let countdowns = render.confidenceInfo.videoCountdowns
            .sorted { $0.key < $1.key }
            .map { layer, countdown in
                let mediaId = LayerKind(rawValue: layer).flatMap { controls.state.liveMedia[$0]?.mediaId }
                let serviceItemId = mediaId.flatMap { controls.mediaFireContexts[$0] }
                return APIVideoCountdown(
                    layer: layer, name: countdown.name, duration: countdown.duration,
                    position: countdown.position, anchoredAt: countdown.anchoredAt,
                    isPlaying: countdown.isPlaying,
                    serviceItemId: serviceItemId)
            }
        return APITimersDocument(timers: timers, videoCountdowns: countdowns)
    }

    private func timers(at now: Date) -> [APITimerStatus] {
        controls.timers.timers.map { timerStatus($0, at: now) }
    }

    private func timerStatus(_ timer: TimerSnapshot, at date: Date) -> APITimerStatus {
        let folder = controls.timers.board.folder(containing: timer.id)
        return APITimerStatus(
            id: timer.id, name: timer.name,
            mode: Self.timerModeKey(timer.mode),
            running: timer.isRunning,
            displaySeconds: Int(timer.value(at: date).rounded()),
            overrun: timer.urgency(at: date) == .overrun,
            folderId: folder?.id, folderName: folder?.name,
            runningSince: timer.runningSince,
            bankedSeconds: timer.banked,
            durationSeconds: timer.durationSeconds,
            targetTime: timer.targetTime,
            armedAt: timer.armedAt,
            warnings: timer.warnings.map {
                APITimerStatus.Warning(remainingSeconds: $0.remainingSeconds, colorHex: $0.colorHex)
            }
        )
    }

    private static func timerModeKey(_ mode: TimerSnapshot.Mode) -> String {
        switch mode {
        case .countdown: "countdown"
        case .countdownToTime: "countdownToTime"
        case .countUp: "countUp"
        }
    }

    func transportRows() -> [APITransportRow] {
        let now = Date()
        return controls.media.rows.map { row in
            APITransportRow(
                mediaId: row.id, name: row.name,
                layer: row.candidate.layer.rawValue,
                playing: row.state.isPlaying,
                looping: row.state.isLooping,
                position: row.state.position(at: now),
                duration: row.state.duration
            )
        }
    }

    func outputsStatus() -> APIOutputsStatus {
        let outputs = render.outputs
        let screens = outputs.placeholderScreens.map { screen in

            let sliceOutputs = outputs.slices(forScreen: screen.id).map { slice in
                let backing: String = if outputs.placeholderDevices[slice.id] != nil {
                    "display"
                } else if NDIScreenOutputs.shared.isCarrying(slice.id) {
                    "ndi"
                } else if DeckLinkScreenOutputs.shared.isCarrying(slice.id) {
                    "decklink"
                } else {
                    "none"
                }
                return APIOutputsStatus.Output(
                    id: slice.id.uuidString, name: slice.name,
                    x: slice.sourceRect.minX, y: slice.sourceRect.minY,
                    width: slice.sourceRect.width, height: slice.sourceRect.height,
                    backing: backing,
                    adjusted: !outputs.adjustments(forScreen: slice.id).isNeutral
                )
            }
            return APIOutputsStatus.Screen(
                id: screen.id.uuidString, name: screen.name,
                role: outputs.role(forScreen: screen.id).rawValue,
                backed: sliceOutputs.contains { $0.backing != "none" },
                width: screen.width, height: screen.height,
                outputs: sliceOutputs,
                activeMasks: outputs.activeMasks(forScreen: screen.id).map(\.name)
            )
        }
        return APIOutputsStatus(screens: screens)
    }

    private struct FirePosition {
        var itemID: String
        var occurrence: Int
        var slide: Slide
        var presentation: Presentation
        var arrangementId: String?
    }

    private func currentService() -> Service? {
        appModel.currentServiceID.flatMap { try? appModel.service($0) }
    }

    private func deckIDs(in service: Service) -> [String] {
        appModel.runOfShow(service).filter { $0.itemKind == .presentation }.map(\.refId)
    }

    private func heldDecks(in service: Service?) -> [String: Presentation]? {
        var decks: [String: Presentation] = [:]
        var complete = true
        for id in service.map(deckIDs(in:)) ?? [] {
            if let deck = appModel.heldPresentation(id) {
                decks[id] = deck
            } else if appModel.presentationExists(id) {
                complete = false
            }
        }
        return complete ? decks : nil
    }

    private func filledDecks(in service: Service) async -> [String: Presentation] {
        await appModel.presentationsFilled(deckIDs(in: service).filter { appModel.presentationExists($0) })
    }

    private func service(containingItem itemID: String) -> Service? {
        if let serviceID = appModel.currentServiceID,
           let service = try? appModel.service(serviceID),
           service.items.contains(where: { $0.id == itemID }) {
            return service
        }
        let entries = appModel.entries(of: .service)
        for entry in entries {
            if let service = try? appModel.service(entry.id),
               service.items.contains(where: { $0.id == itemID }) {
                return service
            }
        }
        return nil
    }

    private func positions(in service: Service, decks: [String: Presentation]) -> [FirePosition] {
        var positions: [FirePosition] = []
        for item in appModel.runOfShow(service) where item.itemKind == .presentation {
            guard let presentation = decks[item.refId] else { continue }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: item.arrangementId
            )
            for (index, slide) in slides.enumerated() {
                positions.append(FirePosition(
                    itemID: item.id, occurrence: index, slide: slide,
                    presentation: presentation, arrangementId: item.arrangementId
                ))
            }
        }
        return positions
    }

    func fireSlide(_ command: APIFireSlideCommand) async throws {

        if let serviceItemId = command.serviceItemId {
            guard let service = service(containingItem: serviceItemId) else {
                throw APIError.notFound("No service contains an item '\(serviceItemId)'.")
            }
            let decks = await filledDecks(in: service)
            let positions = positions(in: service, decks: decks).filter { $0.itemID == serviceItemId }
            guard !positions.isEmpty else {
                throw APIError.notFound(
                    "Service item '\(serviceItemId)' has no firable slides."
                )
            }
            let index = command.occurrence ?? command.slideIndex ?? 0
            guard positions.indices.contains(index) else {
                throw APIError.badRequest(
                    "Occurrence \(index) is out of range (item has \(positions.count) positions)."
                )
            }
            let position = positions[index]
            controls.fire(
                slide: position.slide, in: position.presentation,
                arrangementId: position.arrangementId,
                contextID: position.itemID, occurrence: position.occurrence
            )
            return
        }

        guard let presentationId = command.presentationId,
              let presentation = await libraryDeck(presentationId)
        else {
            throw APIError.notFound("Provide serviceItemId, or a presentationId that exists.")
        }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: command.arrangementId
        )
        let index: Int
        if let slideId = command.slideId {
            guard let found = slides.firstIndex(where: { $0.id == slideId }) else {
                throw APIError.notFound("No slide '\(slideId)' in that presentation's arranged order.")
            }
            index = found
        } else {
            index = command.slideIndex ?? 0
        }
        guard slides.indices.contains(index) else {
            throw APIError.badRequest(
                "Slide index \(index) is out of range (\(slides.count) slides)."
            )
        }
        controls.fire(
            slide: slides[index], in: presentation, arrangementId: command.arrangementId,
            contextID: presentationId, occurrence: index
        )
    }

    private func libraryDeck(_ id: String) async -> Presentation? {
        if let held = appModel.heldPresentation(id) {
            held
        } else if appModel.presentationExists(id) {
            await appModel.presentationsFilled([id])[id]
        } else {
            nil
        }
    }

    func advance(steps: Int, settled: Bool) async throws {
        if steps != 0 {
            let service = currentService()
            if let decks = heldDecks(in: service) {
                try advance(steps: steps, settled: settled, service: service, decks: decks)
            } else if let service {
                try advance(steps: steps, settled: settled, service: service, decks: await filledDecks(in: service))
            }
        }
    }

    func advanceIgnoringErrors(steps: Int, settled: Bool) {
        let service = currentService()
        if let decks = heldDecks(in: service) {
            try? advance(steps: steps, settled: settled, service: service, decks: decks)
        } else {
            Task { [weak self] in
                try? await self?.advance(steps: steps, settled: settled)
            }
        }
    }

    private func advance(steps: Int, settled: Bool, service: Service?, decks: [String: Presentation]) throws {
        if steps != 0 {
            try controls.advance(steps: steps, settled: settled) {
                try advanceSlide(steps: steps, positions: service.map { positions(in: $0, decks: decks) } ?? [])
            }
        }
    }

    private func advanceSlide(steps: Int, positions: [FirePosition]) throws {

        if let contextID = controls.liveContextID, let occurrence = controls.liveOccurrence,
           let current = positions.firstIndex(where: {
               $0.itemID == contextID && $0.occurrence == occurrence
           }) {
            let next = current + steps
            guard positions.indices.contains(next) else {
                throw APIError.badRequest("Already at the \(steps > 0 ? "end" : "start") of the service.")
            }
            let position = positions[next]
            controls.fire(
                slide: position.slide, in: position.presentation,
                arrangementId: position.arrangementId,
                contextID: position.itemID, occurrence: position.occurrence
            )
            return
        }

        if let contextID = controls.liveContextID, let occurrence = controls.liveOccurrence,
           let live = controls.state.liveSlide, let presentation = live.presentation {
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: live.arrangementId
            )
            let next = occurrence + steps
            guard slides.indices.contains(next) else {
                throw APIError.badRequest("Already at the \(steps > 0 ? "end" : "start").")
            }
            controls.fire(
                slide: slides[next], in: presentation, arrangementId: live.arrangementId,
                contextID: contextID, occurrence: next
            )
            return
        }

        guard let position = steps > 0 ? positions.first : positions.last else {
            throw APIError.badRequest("Nothing is live and the current service has no slides.")
        }
        controls.fire(
            slide: position.slide, in: position.presentation,
            arrangementId: position.arrangementId,
            contextID: position.itemID, occurrence: position.occurrence
        )
    }

    func advanceServiceItem(steps: Int) throws {
        guard steps != 0 else { return }
        guard let serviceID = appModel.currentServiceID,
              let service = try? appModel.service(serviceID)
        else { throw APIError.badRequest("No current service.") }
        let items = appModel.fireableItems(service)
        guard !items.isEmpty else {
            throw APIError.badRequest("The current service has no items to fire.")
        }
        let currentIndex = items.firstIndex { $0.id == controls.liveContextID }
            ?? items.firstIndex { $0.itemKind == .media && controls.isMediaLive($0.refId) }
        let target = currentIndex.map { $0 + steps } ?? (steps > 0 ? 0 : items.count - 1)
        guard items.indices.contains(target) else {
            throw APIError.badRequest(
                "Already at the \(steps > 0 ? "last" : "first") service item.")
        }

        var index = target
        while items.indices.contains(index) {
            if controls.fireServiceItem(items[index]) != .unresolvable { return }
            index += steps > 0 ? 1 : -1
        }
        throw APIError.badRequest("No fireable service item that way.")
    }

    func clear(_ command: APIClearCommand) throws {
        if let raw = command.function {
            guard let function = ShowFunction(rawValue: raw) else {
                throw APIError.badRequest(
                    "Unknown function '\(raw)'. Functions: \(ShowFunction.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            controls.clear(function: function)
        } else if let raw = command.layer {
            guard let layer = LayerKind(rawValue: raw) else {
                throw APIError.badRequest(
                    "Unknown layer '\(raw)'. Layers: \(LayerKind.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            controls.clear(layer: layer)
        } else {
            throw APIError.badRequest("Provide either 'function' or 'layer'.")
        }
    }

    func clearAll() {
        controls.clearAll()
    }

    func fireMedia(id: String) throws {
        guard let item = appModel.media(id) else {
            throw APIError.notFound("No media item '\(id)'.")
        }
        controls.fire(mediaItem: item)
    }

    func fireActionCombo(id: String) throws {
        guard (try? appModel.actionCombo(id)) != nil else {
            throw APIError.notFound("No action combo '\(id)'.")
        }
        guard let router = controls.actionRouter else {
            throw APIError.notFound("Actions unavailable.")
        }
        router.fire(comboID: id)
    }

    func fireAlert(_ command: APIFireAlertCommand) throws {
        if let presetId = command.presetId {
            guard let preset = try? appModel.alertPreset(presetId)
            else {
                throw APIError.notFound("No alert preset '\(presetId)'.")
            }

            var values = command.tokens ?? [:]
            for name in AlertTokens.tokenNames(in: preset.message)
            where controls.timers.timers.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                values[name] = "{\(name)}"
            }
            let message = command.message ?? AlertTokens.compose(
                template: preset.message, values: values
            )
            controls.fire(alertPreset: preset, message: message)
            return
        }
        guard let message = command.message, !message.isEmpty else {
            throw APIError.badRequest("Provide 'presetId' or 'message'.")
        }
        let behavior = command.behavior.flatMap(AlertBehavior.init(rawValue:)) ?? .persist
        let target = command.target.flatMap(AlertTarget.init(rawValue:)) ?? .confidence
        controls.fireAlert(
            message: message, behavior: behavior, target: target, themeId: command.themeId
        )
    }

    func dismissAlert() {
        controls.dismissAlert()
    }

    func timerAction(id: String, action: APITimerAction) throws {
        guard controls.timers.snapshot(id: id) != nil else {
            throw APIError.notFound("No timer '\(id)'.")
        }
        switch action {
        case .play: controls.timers.start(id: id)
        case .pause: controls.timers.pause(id: id)
        case .reset: controls.timers.reset(id: id)
        }
    }

    func mediaTransport(id: String, command: APIMediaTransportCommand) throws {
        guard let row = controls.media.rows.first(where: { $0.id == id }) else {
            throw APIError.notFound("No playing video '\(id)'. GET /v1/transport lists them.")
        }
        switch command.action {
        case "toggle":
            controls.media.togglePlayPause(id)
        case "pause":
            if row.state.isPlaying { controls.media.togglePlayPause(id) }
        case "resume":
            if !row.state.isPlaying { controls.media.togglePlayPause(id) }
        case "reset":
            controls.media.resetToStart(id)
        case "seek":
            guard let position = command.position else {
                throw APIError.badRequest("'seek' needs 'position' (seconds).")
            }
            controls.media.seek(id, to: position, final: true)
        default:
            throw APIError.badRequest(
                "Unknown action '\(command.action)'. Actions: toggle, pause, resume, reset, seek."
            )
        }
    }

    func selectService(id: String) throws {
        guard (try? appModel.service(id)) != nil else {
            throw APIError.notFound("No service '\(id)'.")
        }
        appModel.currentServiceID = id
        controls.refreshNextSlide()
    }

    func schedulerStatus() -> APISchedulerStatus {
        let board = appModel.schedulerBoard
        let triggers = appModel.scheduleTriggers.compactMap { entry -> APISchedulerTriggerStatus? in
            guard let trigger = try? appModel.scheduleTrigger(entry.id) else { return nil }
            let folder = board.folder(containing: trigger.id)
            return APISchedulerTriggerStatus(
                id: trigger.id, name: trigger.name,
                enabled: trigger.enabled ?? true,
                folderEnabled: board.folderEnabled(forTrigger: trigger.id),
                folderId: folder?.id, folderName: folder?.name,
                nextFire: scheduler?.upcoming[trigger.id],

                lastFired: scheduler?.history.first {
                    $0.triggerID == trigger.id && $0.outcome != .missed
                }?.at,
                archived: trigger.archived == true ? true : nil
            )
        }
        return APISchedulerStatus(
            enabled: scheduler?.enabled ?? false,
            nextFire: scheduler?.nextFire.map {
                APISchedulerUpcoming(triggerId: $0.triggerID, name: $0.name, at: $0.date)
            },
            triggers: triggers
        )
    }

    func setSchedulerEnabled(_ enabled: Bool) {
        scheduler?.enabled = enabled
    }

    func setScheduleTriggerEnabled(id: String, enabled: Bool) throws {
        let id = try Self.validatedID(id)
        guard (try? appModel.scheduleTrigger(id)) != nil else {
            throw APIError.notFound("No trigger '\(id)'.")
        }

        appModel.updateScheduleTrigger(id) { $0.enabled = enabled ? nil : false }
    }

    func fireScheduleTrigger(id: String) throws {
        let id = try Self.validatedID(id)
        guard (try? appModel.scheduleTrigger(id)) != nil else {
            throw APIError.notFound("No trigger '\(id)'.")
        }
        scheduler?.runNow(triggerID: id)
    }

    func midiDevices() -> [APIMIDIDeviceStatus] {
        let destinations = Set(MIDIDeviceInventory.destinationEndpoints().map(\.uid))
        let sources = Set(MIDIDeviceInventory.sourceEndpoints().map(\.uid))

        return MIDIDeviceInventory.shared.items.map { item in
            APIMIDIDeviceStatus(
                id: item.id,
                name: item.device.name,
                enabled: item.isEnabled,
                direction: item.effectiveDirection.rawValue,
                channel: item.device.channel,
                connected: item.isConnected(destinations: destinations, sources: sources),
                destinationUid: item.destinationUID.map(Int.init),
                sourceUid: item.sourceUID.map(Int.init)
            )
        }
    }

    func setMIDIDeviceEnabled(id: String, enabled: Bool) throws {
        let inventory = MIDIDeviceInventory.shared
        guard let item = inventory.items.first(where: { $0.id == id }) else {
            throw APIError.notFound("No MIDI device '\(id)'. GET /v1/midi/devices lists them.")
        }
        inventory.setEnabled(item, enabled: enabled)
    }

    func videoInputs() -> [APIVideoInputStatus] {
        VideoInputInventory.shared.entries.map { entry in
            APIVideoInputStatus(
                id: entry.id,
                name: entry.name,
                kind: entry.kind?.rawValue,
                sourceId: entry.sourceId,
                audioInputId: entry.audioInputId,
                delayFrames: entry.delayFrames
            )
        }
    }

    func createDocument(kind: APIDocumentKind, body: Data) async throws -> String {
        switch Self.documentKind(kind) {
        case .presentation: try await create(Presentation.self, body: body)
        case .service: try await create(Service.self, body: body)
        case .theme: try await create(Theme.self, body: body)
        case .media: try await create(MediaItem.self, body: body)
        case .playlist: try await create(Playlist.self, body: body)
        case .alertPreset: try await create(AlertPreset.self, body: body)
        case .actionCombo: try await create(ActionCombo.self, body: body)
        case .scheduleTrigger: try await create(ScheduleTrigger.self, body: body)
        case .confidenceLayout: try await create(ConfidenceLayout.self, body: body)
        case .audio, .overlay, .outputPreset, .streamRecordPreset,
            .midiDevice, .streamDestination, .schedulerBoard, .controlBoard, .groupPalette,
            .signageBoard, .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .note, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: throw APIError.notFound("Unknown document kind.")
        }
    }

    func updateDocument(kind: APIDocumentKind, id: String, body: Data) async throws {
        switch Self.documentKind(kind) {
        case .presentation: try await update(Presentation.self, id: id, body: body)
        case .service: try await update(Service.self, id: id, body: body)
        case .theme: try await update(Theme.self, id: id, body: body)
        case .media: try await update(MediaItem.self, id: id, body: body)
        case .playlist: try await update(Playlist.self, id: id, body: body)
        case .alertPreset: try await update(AlertPreset.self, id: id, body: body)
        case .actionCombo: try await update(ActionCombo.self, id: id, body: body)
        case .scheduleTrigger: try await update(ScheduleTrigger.self, id: id, body: body)
        case .confidenceLayout: try await update(ConfidenceLayout.self, id: id, body: body)
        case .audio, .overlay, .outputPreset, .streamRecordPreset,
            .midiDevice, .streamDestination, .schedulerBoard, .controlBoard, .groupPalette,
            .signageBoard, .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .note, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: throw APIError.notFound("Unknown document kind.")
        }
    }

    func deleteDocument(kind: APIDocumentKind, id: String) async throws {
        let id = try Self.validatedID(id)
        do {
            _ = try await appModel.client.delete(kind: Self.documentKind(kind), id: id).value
        } catch {
            throw APIError.notFound("No document with id '\(id)'.")
        }
        appModel.noteExternalMutation()
        controls.refreshNextSlide()
    }

    func addServiceItem(serviceId: String, refId: String, index: Int?) throws {
        guard (try? appModel.service(serviceId)) != nil else {
            throw APIError.notFound("No service '\(serviceId)'.")
        }
        guard appModel.entry(refId) != nil else {
            throw APIError.notFound("No library item '\(refId)'.")
        }
        appModel.addServiceItem(serviceId, refID: refId)
        if let index {
            appModel.updateService(serviceId) { service in
                guard let last = service.items.indices.last, index < last else { return }
                let item = service.items.removeLast()
                service.items.insert(item, at: max(0, index))
            }
        }
        controls.refreshNextSlide()
    }

    @discardableResult
    private func create<E: DocumentEntity>(_ type: E.Type, body: Data) async throws -> String {

        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else {
            throw APIError.badRequest("Body must be a JSON object (the document).")
        }
        if let suppliedID = object["id"] as? String, !suppliedID.isEmpty {
            object["id"] = try Self.validatedID(suppliedID)
        } else {
            object["id"] = UUID().uuidString
        }
        let entity: E
        do {
            let normalized = try JSONSerialization.data(withJSONObject: object)
            entity = try JSONDecoder().decode(E.self, from: normalized)
        } catch {
            throw APIError.badRequest("Not a valid \(String(describing: type)): \(error)")
        }
        do {
            _ = try await appModel.createInDrive(entity).value
        } catch {
            throw APIError(status: 409, code: "conflict", message: "\(error)")
        }
        appModel.noteExternalMutation()
        return entity.id
    }

    private func update<E: DocumentEntity>(_ type: E.Type, id: String, body: Data) async throws {
        let id = try Self.validatedID(id)
        await appModel.client.settled()
        guard (try? await appModel.client.exists(kind: E.documentKind, id: id)) == true else {
            throw APIError.notFound("No document with id '\(id)'.")
        }
        var entity: E
        do {
            entity = try JSONDecoder().decode(E.self, from: body)
        } catch {
            throw APIError.badRequest("Not a valid \(String(describing: type)): \(error)")
        }
        guard entity.id == id else {
            throw APIError.badRequest("Body id '\(entity.id)' does not match the path id '\(id)'.")
        }
        do {
            let value = entity
            _ = try await appModel.client.modify(type, id: id) { $0 = value }.value
        } catch {
            throw APIError(status: 500, code: "write_failed", message: "\(error)")
        }
        appModel.noteExternalMutation()
        controls.refreshNextSlide()
    }
}
