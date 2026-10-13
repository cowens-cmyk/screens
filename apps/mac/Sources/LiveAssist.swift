import Observation
import PresenterCore
import SlideScene
import Speech
import SwiftUI

/// Listens to the room and helps the operator: follows the song and moves to
/// the next slide as it's sung (with a confidence meter and instant manual
/// takeover), and spots spoken Bible references ("turn to Genesis 32") so
/// the passage is one click away.
@MainActor
@Observable
final class LiveAssist {
    static let shared = LiveAssist()

    private static let deviceKey = "liveAssist.deviceUID"

    var deviceUID: String {
        didSet {
            UserDefaults.standard.set(deviceUID, forKey: Self.deviceKey)
            if deviceUID != oldValue { channel = nil; restartIfListening() }
        }
    }
    /// One input channel (the worship leader's mic on an interface), or
    /// nil for the first pair.
    var channel: Int? {
        didSet {
            UserDefaults.standard.set(channel ?? -1, forKey: "liveAssist.channel")
            if channel != oldValue { restartIfListening() }
        }
    }
    private(set) var level: Float = 0
    var followsLyrics = false
    var detectsScripture = true
    /// Below this, the follower only suggests; the operator decides.
    var autoAdvanceConfidence = 0.7

    private(set) var listening = false
    private(set) var status = "Off"
    private(set) var transcript = ""
    private(set) var lastDecision: LyricFollower.Decision?
    private(set) var detected: [BibleReference] = []
    private(set) var pausedUntil: Date?

    private let transcriber = LiveTranscriber()
    private var follower: LyricFollower?
    private var followerKey = ""
    private var lastHeardFinal = ""
    private weak var controls: ServiceControls?
    private weak var model: AppModel?
    private var lastAutoFire = Date.distantPast
    private var lastLiveSignature = ""

    private init() {
        deviceUID = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        let storedChannel = UserDefaults.standard.object(forKey: "liveAssist.channel") as? Int ?? -1
        channel = storedChannel >= 0 ? storedChannel : nil
        transcriber.onText = { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
        transcriber.onLevel = { [weak self] level in self?.level = level }
        transcriber.onState = { [weak self] state in self?.update(state) }
    }

    func attach(model: AppModel, controls: ServiceControls) {
        self.model = model
        self.controls = controls
    }

    func start() async {
        if deviceUID.isEmpty || !LiveTranscriber.inputDevices().contains(where: { $0.uid == deviceUID }) {
            deviceUID = LiveTranscriber.inputDevices().first?.uid ?? ""
        }
        guard !deviceUID.isEmpty else {
            status = "Choose an audio input"
            return
        }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else {
            status = "Allow Speech Recognition in System Settings › Privacy & Security"
            return
        }
        transcriber.start(
            deviceUID: deviceUID, channels: channel.map { .mono(channel: $0) } ?? .default)
    }

    private func restartIfListening() {
        guard listening else { return }
        Task { await start() }
    }

    func stop() {
        transcriber.stop()
        listening = false
        level = 0
        status = "Off"
    }

    /// Any manual move pauses following briefly so the operator stays in charge.
    func operatorTookOver() {
        pausedUntil = Date().addingTimeInterval(8)
        follower?.reset()
    }

    private func update(_ state: LiveTranscriber.State) {
        switch state {
        case .idle: listening = false; status = "Off"
        case .preparing: status = "Preparing speech model…"
        case .listening: listening = true; status = "Listening"
        case .failed(let message): listening = false; status = message
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        transcript = String((lastHeardFinal + " " + text).suffix(400))
        if isFinal { lastHeardFinal = String((lastHeardFinal + " " + text).suffix(600)) }
        if detectsScripture, isFinal { spotScripture(in: text) }
        if followsLyrics { follow(text, isFinal: isFinal) }
    }

    private func spotScripture(in text: String) {
        for reference in SpokenReference.references(in: text) where !detected.contains(reference) {
            detected.insert(reference, at: 0)
        }
        if detected.count > 12 { detected.removeLast(detected.count - 12) }
    }

    // MARK: Lyric following

    private func follow(_ text: String, isFinal: Bool) {
        guard let controls, let live = controls.state.liveSlide, let presentation = live.presentation,
              presentation.presentationKind == .song || presentation.category == PresentationTypes.worship
        else { return }
        let slides = SlideSceneBuilder.arrangedSlides(for: presentation, arrangementId: live.arrangementId)
        let key = "\(presentation.id)|\(live.arrangementId ?? "")|\(slides.count)"
        if key != followerKey {
            followerKey = key
            follower = LyricFollower(slideTexts: slides.map { ConfidenceSceneBuilder.lyricText(for: $0) })
        }
        let signature = "\(live.slide.id)|\(controls.liveOccurrence ?? -1)"
        if signature != lastLiveSignature {
            // The slide changed (by us or the operator): listen fresh.
            lastLiveSignature = signature
            follower?.reset()
        }
        guard isFinal || text.split(separator: " ").count >= 3 else { return }
        follower?.hear(text)
        guard var follower else { return }
        let current = controls.liveOccurrence ?? slides.firstIndex { $0.id == live.slide.id } ?? 0
        let decision = follower.decision(current: current)
        self.follower = follower
        lastDecision = decision
        guard let decision, decision.confidence >= autoAdvanceConfidence,
              pausedUntil.map({ Date() > $0 }) ?? true,
              Date().timeIntervalSince(lastAutoFire) > 1.5,
              slides.indices.contains(decision.slideIndex)
        else { return }
        lastAutoFire = Date()
        controls.fire(
            slide: slides[decision.slideIndex], in: presentation, arrangementId: live.arrangementId,
            contextID: controls.liveContextID, occurrence: decision.slideIndex)
        DiagnosticsStore.shared.note(
            "liveAssist.advance", detail: "\(decision.reason) \(Int(decision.confidence * 100))%")
    }

    // MARK: Scripture

    /// Builds the passage with the Bible template and puts its first slide live.
    func show(_ reference: BibleReference) async throws {
        guard let model, let controls else { return }
        let settings = BibleSettings.shared
        if settings.translation == nil { await settings.refreshTranslations() }
        guard let translation = settings.translation else { throw BibleError.missingKey("API.Bible or ESV") }
        let passage = try await settings.service.passage(reference, translation: translation)
        let themeID = model.slideBuilding.scriptureThemeId ?? ""
        await model.themesFilled([themeID])
        var presentation = ScriptureSlideBuilder.presentation(
            for: passage, format: settings.format, theme: model.theme(themeID))
        presentation.folder = model.newPlacement.folder(for: .presentation)
        model.createInDrive(presentation)
        if let first = presentation.slides.first {
            controls.fire(slide: first, in: presentation)
        }
    }
}

struct LiveAssistView: View {
    @Bindable private var assist = LiveAssist.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section("Microphone") {
                LiveAssistInputPicker()
            }
            Section {
                HStack {
                    Circle().fill(assist.listening ? .green : .secondary).frame(width: 8, height: 8)
                    Text(assist.status).font(.callout)
                    Spacer()
                    Button(assist.listening ? "Stop" : "Start Listening") {
                        if assist.listening { assist.stop() } else { Task { await assist.start() } }
                    }
                }
                Text(assist.transcript.isEmpty ? "…" : assist.transcript)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text("Lyric following and scripture detection options are in Settings › Show Setup.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if assist.followsLyrics {
                Section("Lyric Following") {
                    ConfidenceMeter(decision: assist.lastDecision, threshold: assist.autoAdvanceConfidence)
                    Button("Take Over (pause 8 s)") { assist.operatorTookOver() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            Section("Scripture Detection") {
                if assist.detected.isEmpty {
                    Text("When the pastor says “turn to Genesis 32”, it appears here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(assist.detected, id: \.self) { reference in
                    HStack {
                        Text(reference.display)
                        Spacer()
                        Button("Show") {
                            Task {
                                do { try await assist.show(reference) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 520)
    }
}

private struct ConfidenceMeter: View {
    let decision: LyricFollower.Decision?
    let threshold: Double

    var body: some View {
        let value = decision?.confidence ?? 0
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: value)
                .tint(value >= threshold ? .green : value >= 0.4 ? .yellow : .gray)
            Text(label(value)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func label(_ value: Double) -> String {
        guard let decision else { return "Listening for the next line…" }
        let what = switch decision.reason {
        case .nextSlideStarted: "next slide started"
        case .currentSlideFinished: "slide finished"
        case .jump: "jumped to slide \(decision.slideIndex + 1)"
        }
        return "\(Int(value * 100))% — \(what)"
    }
}

/// Which microphone (and which channel of an interface) Live Assist hears,
/// with a level meter to confirm it.
struct LiveAssistInputPicker: View {
    @Bindable private var assist = LiveAssist.shared
    @State private var devices = LiveTranscriber.inputDevices()

    private var channels: Int { devices.first { $0.uid == assist.deviceUID }?.channels ?? 0 }

    var body: some View {
        Picker("Listen to", selection: $assist.deviceUID) {
            if !devices.contains(where: { $0.uid == assist.deviceUID }) {
                Text("Choose a microphone…").tag(assist.deviceUID)
            }
            ForEach(devices, id: \.uid) { device in
                Text(device.channels > 2 ? "\(device.name) (\(device.channels) ch)" : device.name).tag(device.uid)
            }
        }
        .onAppear { devices = LiveTranscriber.inputDevices() }
        if channels > 1 {
            Picker("Channel", selection: $assist.channel) {
                Text(channels > 2 ? "Channels 1–2" : "Both").tag(Int?.none)
                ForEach(0..<channels, id: \.self) { Text("Channel \($0 + 1)").tag(Int?.some($0)) }
            }
        }
        HStack {
            Text("Level").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(assist.level))
                .tint(assist.level > 0.9 ? .red : .green)
            if !assist.listening {
                Text("Start listening to check").font(.caption).foregroundStyle(.tertiary)
            }
        }
        Button("Refresh Inputs") { devices = LiveTranscriber.inputDevices() }
            .controlSize(.small)
    }
}
