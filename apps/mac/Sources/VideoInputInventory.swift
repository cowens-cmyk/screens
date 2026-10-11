import AVFoundation
import AudioEngine
import Foundation
import MediaEngine
import NDIKit
import Observation
import PresenterCore

@MainActor
@Observable
final class VideoInputInventory {
    static let shared = VideoInputInventory()

    struct Entry: Codable, Identifiable, Equatable {

        var id: String
        var name: String

        var kind: CaptureSourceKind?
        var sourceId: String?

        var audioInputId: String?

        var delayFrames: Int?

        var frameRate: Double?

        // Web Page inputs: output size and whether the page's audio is muted. `sourceId` is the URL.
        var width: Int?
        var height: Int?
        var pageMuted: Bool?

        var engineID: String { "input::item::\(id)" }
        var isAssigned: Bool { kind != nil && sourceId?.isEmpty == false }

        init(
            id: String = UUID().uuidString, name: String,
            kind: CaptureSourceKind? = nil, sourceId: String? = nil,
            audioInputId: String? = nil, delayFrames: Int? = nil,
            frameRate: Double? = nil, width: Int? = nil, height: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.sourceId = sourceId
            self.audioInputId = audioInputId
            self.delayFrames = delayFrames
            self.frameRate = frameRate
            self.width = width
            self.height = height
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decode(String.self, forKey: .name)
            kind = try container.decodeIfPresent(CaptureSourceKind.self, forKey: .kind)
            sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
            audioInputId = try container.decodeIfPresent(String.self, forKey: .audioInputId)
            delayFrames = try container.decodeIfPresent(Int.self, forKey: .delayFrames)
            frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            pageMuted = try container.decodeIfPresent(Bool.self, forKey: .pageMuted)
        }
    }

    static let engineIDPrefix = "input::item::"

    private(set) var entries: [Entry] = []
    private static let defaultsKey = "videoInputs.inventory"
    private var render: RenderContext?

    private var running: Set<String> = []

    var onEntriesChanged: (() -> Void)?

    private var ndiSources: [String: NDIInputSource] = [:]
    private var webSources: [String: WebInputSource] = [:]
    private var decklinkSources: [String: DeckLinkInputClient] = [:]

    // DeckLink capture status per entry id, refreshed by the connectivity poll for the Settings UI.
    private(set) var decklinkStates: [String: DeckLinkInputClient.State] = [:]

    static let webDefaultWidth = 1920
    static let webDefaultHeight = 1080
    static let webDefaultFrameRate = 30

    var onConnectedChanged: (([String]) -> Void)?
    private var connectivityTimer: Timer?
    private var lastConnected: [String] = []

    private var hotplugObservers: [any NSObjectProtocol] = []
    private var cameraDiscovery: AVCaptureDevice.DiscoverySession?

    private var hotplugStartAttempts: [String: CFTimeInterval] = [:]

    private init() {
        MediaEngine.captureNote.value = { DiagnosticsStore.shared.note("input.camera", detail: $0) }
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
            shareDeviceRates()

            persist()
        }
        syncPlaceholderKinds()
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func entry(forEngineID engineID: String) -> Entry? {
        guard engineID.hasPrefix(Self.engineIDPrefix) else { return nil }
        return entry(id: String(engineID.dropFirst(Self.engineIDPrefix.count)))
    }

    func isInventoried(engineID: String) -> Bool {
        entry(forEngineID: engineID) != nil
    }

    func warmUp(render: RenderContext) {
        self.render = render
        startConnectivityPoll()
        startHotplugWatch()
        for entry in entries where entry.kind == .ndi { start(entry) }
        for entry in entries where entry.kind == .web && entry.isAssigned { start(entry) }
        for entry in entries where entry.kind == .decklink && entry.isAssigned { start(entry) }
        let cameras = entries.filter { $0.kind == .camera && $0.isAssigned }
        guard !cameras.isEmpty else { return }
        withCameraPermission { [weak self] granted in
            guard granted, let self else { return }
            for entry in cameras { self.start(entry) }
        }
    }

    @discardableResult
    func create(
        name: String, kind: CaptureSourceKind? = nil, sourceId: String? = nil
    ) -> Entry {
        let entry = Entry(name: name, kind: kind, sourceId: sourceId)
        entries.append(entry)
        persist()
        if entry.isAssigned { startWithPermission(entry) }
        return entry
    }

    @discardableResult
    func createWeb(name: String, url: String, width: Int, height: Int, frameRate: Double) -> Entry {
        let entry = Entry(
            name: name, kind: .web, sourceId: url, frameRate: frameRate,
            width: width, height: height)
        entries.append(entry)
        persist()
        start(entry)
        return entry
    }

    @discardableResult
    func importEntry(
        id: String, name: String, kind: CaptureSourceKind?, sourceId: String?
    ) -> Bool {
        guard entry(id: id) == nil else { return false }
        let entry = Entry(id: id, name: name, kind: kind, sourceId: sourceId)
        entries.append(entry)
        persist()
        if entry.isAssigned { startWithPermission(entry) }
        return true
    }

    func rename(id: String, to name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[index].name = trimmed
        persist()
        webSources[id]?.rename(trimmed)
    }

    func assignDevice(id: String, kind: CaptureSourceKind?, sourceId: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        if kind == .web, entries[index].kind == .web, let sourceId, let source = webSources[id] {
            entries[index].sourceId = sourceId
            persist()
            source.load(sourceId)
            return
        }
        render?.media.stop(id: entries[index].engineID)
        running.remove(id)
        webSources[id]?.stop()
        webSources[id] = nil
        stopDeckLink(id: id)
        entries[index].kind = kind
        entries[index].sourceId = sourceId

        entries[index].frameRate = nil
        shareDeviceRates()
        persist()
        let entry = entries[index]
        if entry.isAssigned { startWithPermission(entry) }
    }

    func assignWeb(id: String, url: String, width: Int, height: Int, frameRate: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        render?.media.stop(id: entries[index].engineID)
        running.remove(id)
        ndiSources[id] = nil
        webSources[id]?.stop()
        webSources[id] = nil
        stopDeckLink(id: id)
        entries[index].kind = .web
        entries[index].sourceId = url
        entries[index].frameRate = frameRate
        entries[index].width = width
        entries[index].height = height
        shareDeviceRates()
        persist()
        start(entries[index])
    }

    func assignAudioInput(id: String, audioInputId: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].audioInputId = audioInputId
        persist()
    }

    func setDelay(id: String, frames: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(frames, LiveInputDelay.maxFrames))
        entries[index].delayFrames = clamped == 0 ? nil : clamped
        persist()
        render?.media.setInputDelay(id: entries[index].engineID, frames: clamped)
        DiagnosticsStore.shared.note(
            "input.camera", detail: "delay \(clamped)f: \(entries[index].name)")
    }

    func setFrameRate(id: String, rate: Double?) {
        if let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .web {
            entries[index].frameRate = rate
            persist()
            reconfigureWeb(entries[index])
            return
        }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let mates = deviceMates(of: entries[index])
            for mate in mates {
                render?.media.stop(id: entries[mate].engineID)
                running.remove(entries[mate].id)
                entries[mate].frameRate = rate
            }
            persist()
            for mate in mates where entries[mate].isAssigned { startWithPermission(entries[mate]) }
        }
    }

    func setWebResolution(id: String, width: Int, height: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].width = width
        entries[index].height = height
        persist()
        reconfigureWeb(entries[index])
    }

    func setPageMuted(id: String, muted: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].pageMuted ?? false != muted
        else { return }
        entries[index].pageMuted = muted ? true : nil
        persist()
        webSources[id]?.setMuted(muted)
    }

    func webSource(id: String) -> WebInputSource? {
        webSources[id]
    }

    func showWebWindow(id: String) {
        if let source = webSources[id] {
            source.showWindow()
        } else if let entry = entry(id: id), entry.kind == .web, entry.isAssigned {
            start(entry)
        }
    }

    private func reconfigureWeb(_ entry: Entry) {
        let size = Self.webSize(entry)
        webSources[entry.id]?.reconfigure(
            width: size.width, height: size.height, framesPerSecond: size.fps)
    }

    static func webSize(_ entry: Entry) -> (width: Int, height: Int, fps: Int) {
        (
            entry.width ?? webDefaultWidth, entry.height ?? webDefaultHeight,
            entry.frameRate.map { Int($0.rounded()) } ?? webDefaultFrameRate
        )
    }

    private func deviceMates(of entry: Entry) -> [Int] {
        entries.indices.filter {
            entries[$0].id == entry.id
                || (entry.kind == .camera && entries[$0].kind == .camera
                    && entries[$0].sourceId == entry.sourceId)
        }
    }

    private func shareDeviceRates() {
        let cameras = entries.filter { $0.kind == .camera }
        let shared = CaptureFormatChoice.sharedRates(
            cameras.map { (device: $0.sourceId ?? "", rate: $0.frameRate) })
        for index in entries.indices where entries[index].kind == .camera {
            entries[index].frameRate = shared[entries[index].sourceId ?? ""]
        }
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
        render?.media.stop(id: entry.engineID)
        running.remove(entry.id)
        ndiSources[entry.id] = nil
        webSources[entry.id]?.stop()
        webSources[entry.id] = nil
        stopDeckLink(id: entry.id)
    }

    func decklinkState(id: String) -> DeckLinkInputClient.State? {
        decklinkStates[id]
    }

    private func stopDeckLink(id: String) {
        decklinkSources[id]?.stop()
        decklinkSources[id] = nil
        decklinkStates[id] = nil
    }

    func startIfNeeded(engineID: String) {
        guard let entry = entry(forEngineID: engineID), entry.isAssigned else {
            DiagnosticsStore.shared.note(
                "input.camera", detail: "unknown or unassigned input: \(engineID)")
            return
        }
        guard !running.contains(entry.id) else { return }
        startWithPermission(entry)
    }

    private func startWithPermission(_ entry: Entry) {
        if entry.kind == .camera {
            withCameraPermission { [weak self] granted in
                guard granted else { return }
                self?.start(entry)
            }
        } else {
            start(entry)
        }
    }

    private func withCameraPermission(_ then: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            then(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if !granted {
                        DiagnosticsStore.shared.note(
                            "input.camera", detail: "permission declined")
                    }
                    then(granted)
                }
            }
        case .denied, .restricted:
            DiagnosticsStore.shared.note(
                "input.camera",
                detail: "permission denied — enable in System Settings › Privacy › Camera")
            then(false)
        @unknown default:
            then(false)
        }
    }

    private func start(_ entry: Entry) {
        guard let render, let kind = entry.kind, let sourceId = entry.sourceId,
              !sourceId.isEmpty, !running.contains(entry.id)
        else { return }
        switch kind {
        case .camera:

            guard let device = AVCaptureDevice(uniqueID: sourceId) else {
                DiagnosticsStore.shared.note(
                    "input.camera", detail: "assigned device missing: \(entry.name)")
                return
            }
            do {
                try render.media.startCapture(
                    device: device, id: entry.engineID, frameRate: entry.frameRate)
                running.insert(entry.id)
                DiagnosticsStore.shared.note("input.camera", detail: "warm: \(entry.name)")
            } catch {
                DiagnosticsStore.shared.note("input.camera", detail: "warm-up failed: \(error)")
            }
        case .ndi:
            do {
                let library = try NDILibrary.load()
                let input = NDIInputSource(library: library, sourceNameContaining: sourceId)
                render.media.registerLiveSource(
                    id: entry.engineID,
                    latestFrame: { input.latestFrame() },
                    onStop: { input.stop() })
                ndiSources[entry.id] = input
                running.insert(entry.id)
            } catch {

                DiagnosticsStore.shared.note("input.ndi", detail: "runtime unavailable: \(error)")
                return
            }
        case .web:
            let size = Self.webSize(entry)
            let source = WebInputSource(
                name: entry.name, url: sourceId, width: size.width, height: size.height,
                framesPerSecond: size.fps, muted: entry.pageMuted ?? false)
            let frames = source.frames
            render.media.registerLiveSource(
                id: entry.engineID,
                latestFrame: { frames.value },
                onStop: { Task { @MainActor in source.stop() } })
            let entryID = entry.id
            source.onMuteChanged = { [weak self] muted in
                self?.setPageMuted(id: entryID, muted: muted)
            }
            webSources[entry.id] = source
            running.insert(entry.id)
            source.start()
        case .decklink:
            // sourceId is the port's BMDDeckLinkPersistentID. Capture runs in the DeckLink helper.
            guard let persistentID = Int64(sourceId) else {
                DiagnosticsStore.shared.note(
                    "input.decklink", detail: "bad DeckLink port id \(sourceId): \(entry.name)")
                return
            }
            let client = DeckLinkInputClient(persistentID: persistentID, name: entry.name)
            render.media.registerLiveSource(
                id: entry.engineID,
                latestFrame: { client.latestFrame() },
                onStop: { client.stop() })
            decklinkSources[entry.id] = client
            decklinkStates[entry.id] = .starting
            running.insert(entry.id)
            client.start()
        }

        render.media.setInputDelay(id: entry.engineID, frames: entry.delayFrames ?? 0)
    }

    func restNDIForRuntimeSwap() -> [Entry] {
        let resting = entries.filter { $0.kind == .ndi && running.contains($0.id) }
        for entry in resting {
            render?.media.stop(id: entry.engineID)
            running.remove(entry.id)
            ndiSources[entry.id] = nil
        }
        return resting
    }

    func rewarmAfterRuntimeSwap(_ rested: [Entry]) {
        for entry in rested { start(entry) }
    }

    private func startHotplugWatch() {
        guard hotplugObservers.isEmpty else { return }
        cameraDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        for name in [AVCaptureDevice.wasConnectedNotification,
                     AVCaptureDevice.wasDisconnectedNotification] {
            hotplugObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    VideoInputInventory.shared.reconcileCameraHotplug()
                }
            })
        }
    }

    private func reconcileCameraHotplug() {
        for entry in entries where entry.kind == .camera && entry.isAssigned {
            guard let sourceId = entry.sourceId else { continue }
            let present = AVCaptureDevice(uniqueID: sourceId) != nil
            switch InputHotplug.decide(
                devicePresent: present, captureLive: running.contains(entry.id)) {
            case .suspend:
                render?.media.stop(id: entry.engineID)
                running.remove(entry.id)

                hotplugStartAttempts[entry.id] = nil
                DiagnosticsStore.shared.note(
                    "input.camera",
                    detail: "device unplugged: \(entry.name) — holding for replug")
            case .start:
                let now = CACurrentMediaTime()
                if let last = hotplugStartAttempts[entry.id], now - last < 5 { break }
                hotplugStartAttempts[entry.id] = now
                startWithPermission(entry)
            case .none:
                break
            }
        }
    }

    private static let cameraGrantCheckInterval: Double = 10
    private var cameraGrantCheckedAt: Double = -.infinity
    private var cameraGranted = false

    private func startConnectivityPoll() {
        guard connectivityTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in VideoInputInventory.shared.pollConnectivity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        connectivityTimer = timer
    }

    private func pollConnectivity() {
        guard let render else { return }
        let now = CACurrentMediaTime()

        if now - cameraGrantCheckedAt >= Self.cameraGrantCheckInterval {
            cameraGrantCheckedAt = now
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
        if cameraGranted {
            reconcileCameraHotplug()
        }
        var connected: [String] = []
        for entry in entries where running.contains(entry.id) {
            switch entry.kind {
            case .camera:

                if let age = render.media.captureFrameAge(id: entry.engineID, at: now), age < 2 {
                    connected.append(entry.id)
                }
            case .ndi:
                if case .receiving = ndiSources[entry.id]?.state {
                    connected.append(entry.id)
                }
            case .web:
                guard let source = webSources[entry.id] else { break }
                source.retryIfPermitted()
                if source.isReceiving { connected.append(entry.id) }
            case .decklink:
                guard let client = decklinkSources[entry.id] else { break }
                let state = client.state
                if decklinkStates[entry.id] != state { decklinkStates[entry.id] = state }
                if case .receiving = state { connected.append(entry.id) }
            case nil:
                break
            }
        }
        let sorted = connected.sorted()
        guard sorted != lastConnected else { return }
        lastConnected = sorted
        onConnectedChanged?(sorted)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        syncPlaceholderKinds()
        onEntriesChanged?()
    }

    private func syncPlaceholderKinds() {
        LiveInputPlaceholder.webEngineIDs.value = Set(
            entries.filter { $0.kind == .web }.map(\.engineID))
    }
}
