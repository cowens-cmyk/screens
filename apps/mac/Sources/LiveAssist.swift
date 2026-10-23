import AVFoundation
import Observation
import PresenterCore
import SlideScene
import Speech
import SwiftUI

/// Listens to the room and helps the operator: follows a song the operator
/// turned Follow on for and highlights or puts up the next slide as it's sung
/// (with a confidence meter and instant manual takeover), and spots spoken
/// Bible references ("turn to Genesis 32") so the passage is one click away.
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
    /// The pastor's mic for sermon listening, kept apart from the worship input.
    var sermonDeviceUID: String {
        didSet {
            UserDefaults.standard.set(sermonDeviceUID, forKey: "liveAssist.sermon.deviceUID")
            if sermonDeviceUID != oldValue { sermonChannel = nil; restartIfListening() }
        }
    }
    var sermonChannel: Int? {
        didSet {
            UserDefaults.standard.set(sermonChannel ?? -1, forKey: "liveAssist.sermon.channel")
            if sermonChannel != oldValue { restartIfListening() }
        }
    }

    enum Mode { case worship, sermon }
    private(set) var mode: Mode = .worship

    /// Everything said during the sermon, newest last.
    private(set) var sermonTranscript = ""
    /// Passages built as soon as they're heard, so Show is instant.
    private(set) var prepared: [String: Presentation] = [:]
    /// Puts each newly spoken passage live by itself.
    var showsAutomatically = true {
        didSet { UserDefaults.standard.set(showsAutomatically, forKey: "liveAssist.sermon.autoShow") }
    }

    private(set) var level: Float = 0
    /// Off: a followed song only highlights the next slide; the operator
    /// puts it up.
    var advancesAutomatically = true {
        didSet { UserDefaults.standard.set(advancesAutomatically, forKey: "liveAssist.follow.advances") }
    }
    var detectsScripture = true
    /// Below this, the follower only suggests; the operator decides.
    var autoAdvanceConfidence = 0.7 {
        didSet { UserDefaults.standard.set(autoAdvanceConfidence, forKey: "liveAssist.follow.confidence") }
    }

    private(set) var listening = false
    /// Between Start and the first words: permissions, the speech model.
    private(set) var starting = false
    private(set) var status = "Off"
    private(set) var transcript = ""
    /// What the follower would do next, for the confidence meter.
    private(set) var lastDecision: LyricFollower.Decision?
    /// Where it thinks the singer is in the live song.
    private(set) var followPosition: LyricFollower.Position?
    /// References heard, newest first; an ambiguous one lists its other readings.
    private(set) var detected: [SpokenDetection] = []
    /// Following holds off until then after the operator moves a slide.
    private(set) var pausedUntil: Date?

    // MARK: Follow state

    /// Songs the operator turned Follow on for. Not saved: each service
    /// starts with Follow off, so the microphone opens only when asked.
    private(set) var followedSongIDs: Set<String> = []
    /// Follow every song that goes live, not only the ones turned on.
    var followsEverySong = false {
        didSet {
            guard followsEverySong != oldValue else { return }
            DiagnosticsStore.shared.note("liveAssist.follow", detail: followsEverySong ? "every song on" : "every song off")
            if followsEverySong { listenForLyrics() } else { stopIfNothingFollowed() }
        }
    }

    /// The slide the follower thinks comes next, highlighted in the grid.
    struct Suggestion: Equatable {
        var presentationID: String
        var contextID: String?
        /// The live slide it was made from: it stands only while that slide is up.
        var fromOccurrence: Int
        var slideIndex: Int
        /// "6 Chorus".
        var label: String
    }
    /// Changes only when the suggested slide does, so tiles redraw rarely;
    /// the confidence moves separately.
    private(set) var suggestion: Suggestion?
    private(set) var suggestionConfidence = 0.0

    private let transcriber = LiveTranscriber()
    private var follower: LyricFollower?
    private var followerKey = ""
    private var lastHeardFinal = ""
    private weak var controls: ServiceControls?
    private weak var model: AppModel?
    private var lastAutoFire = Date.distantPast
    /// The live slide the follower is anchored to ("context|occurrence|slide").
    private var liveSignature = ""
    /// An advance that hasn't landed yet (a transition can hold it back):
    /// until it does, the old slide still being live isn't the operator.
    private var landing: (from: String, until: Date)?
    private var pauseEnd: Task<Void, Never>?
    /// Listening began because of Follow, so it stops when nothing is followed.
    private var listeningForFollow = false

    private init() {
        deviceUID = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        let storedChannel = UserDefaults.standard.object(forKey: "liveAssist.channel") as? Int ?? -1
        channel = storedChannel >= 0 ? storedChannel : nil
        sermonDeviceUID = UserDefaults.standard.string(forKey: "liveAssist.sermon.deviceUID") ?? ""
        let sermonStored = UserDefaults.standard.object(forKey: "liveAssist.sermon.channel") as? Int ?? -1
        sermonChannel = sermonStored >= 0 ? sermonStored : nil
        // On unless turned off: a heard passage should just appear.
        showsAutomatically = UserDefaults.standard.object(forKey: "liveAssist.sermon.autoShow") as? Bool ?? true
        advancesAutomatically = UserDefaults.standard.object(forKey: "liveAssist.follow.advances") as? Bool ?? true
        let confidence = UserDefaults.standard.double(forKey: "liveAssist.follow.confidence")
        autoAdvanceConfidence = (0.5...0.95).contains(confidence) ? confidence : 0.7
        transcriber.onText = { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
        transcriber.onLevel = { [weak self] level in self?.level = level }
        transcriber.onState = { [weak self] state in self?.update(state) }
    }

    func attach(model: AppModel, controls: ServiceControls) {
        self.model = model
        self.controls = controls
    }

    /// Listens to the pastor: a running transcript and every Bible
    /// reference as it's said.
    func startSermon() async {
        mode = .sermon
        if sermonDeviceUID.isEmpty { sermonDeviceUID = deviceUID }
        await start()
    }

    func startWorship() async {
        mode = .worship
        await start()
    }

    func start() async {
        starting = true
        defer { if transcriber.state != .preparing { starting = false } }
        let devices = LiveTranscriber.inputDevices()
        if mode == .sermon {
            if !devices.contains(where: { $0.uid == sermonDeviceUID }) { sermonDeviceUID = devices.first?.uid ?? "" }
        } else if deviceUID.isEmpty || !devices.contains(where: { $0.uid == deviceUID }) {
            deviceUID = devices.first?.uid ?? ""
        }
        let device = mode == .sermon ? sermonDeviceUID : deviceUID
        let inputChannel = mode == .sermon ? sermonChannel : channel
        guard !device.isEmpty else {
            status = "Choose an audio input"
            return
        }
        // Starting is always something the operator just did, so asking for
        // the microphone here is expected (never at launch: see
        // AudioInputInventory).
        guard await Self.microphoneAuthorized() else {
            status = "Allow the microphone in System Settings › Privacy & Security"
            return
        }
        let authorized = await Self.speechAuthorized()
        guard authorized else {
            status = "Allow Speech Recognition in System Settings › Privacy & Security"
            return
        }
        transcriber.start(
            deviceUID: device, channels: inputChannel.map { .mono(channel: $0) } ?? .default)
    }

    nonisolated private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// macOS answers the permission request on a background queue; the
    /// callback must not be main-actor isolated or Swift traps on the hop.
    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func restartIfListening() {
        guard listening else { return }
        Task { await start() }
    }

    func stop() {
        transcriber.stop()
        listening = false
        starting = false
        listeningForFollow = false
        level = 0
        status = "Off"
        clearSuggestion()
    }

    /// Any manual move pauses following briefly so the operator stays in
    /// charge, unless it put up the slide that was suggested. `occurrence`
    /// and `contextID` name the slide being fired, when the caller knows it.
    func operatorTookOver(firing occurrence: Int? = nil, contextID: String? = nil) {
        guard followsEverySong || !followedSongIDs.isEmpty else { return }
        if let suggestion, let controls {
            let fired = occurrence ?? controls.liveOccurrence
            let context = occurrence == nil ? controls.liveContextID : contextID
            if fired == suggestion.slideIndex, context == suggestion.contextID { return }
        }
        takeOver()
    }

    var isPaused: Bool { pausedUntil.map { Date() < $0 } ?? false }

    /// Holds following off for 8 s: it keeps listening and suggesting, and
    /// advances nothing.
    func takeOver() {
        pausedUntil = Date().addingTimeInterval(8)
        pauseEnd?.cancel()
        pauseEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.pausedUntil = nil
        }
    }

    private func update(_ state: LiveTranscriber.State) {
        switch state {
        case .idle: listening = false; starting = false; status = "Off"
        case .preparing: starting = true; status = "Preparing speech model…"
        case .listening: listening = true; starting = false; status = "Listening"
        case .failed(let message): listening = false; starting = false; status = message
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        transcript = String((lastHeardFinal + " " + text).suffix(400))
        if isFinal { lastHeardFinal = String((lastHeardFinal + " " + text).suffix(600)) }
        if mode == .sermon {
            if isFinal { sermonTranscript = String((sermonTranscript + "\n" + text).suffix(8000)) }
            if isFinal { spotScripture(in: text) }
            return
        }
        if detectsScripture, isFinal { spotScripture(in: text) }
        follow(text, isFinal: isFinal)
    }

    private func spotScripture(in text: String) {
        for detection in SpokenReference.detections(in: text, recent: detected.map(\.reference))
        where !detected.contains(where: { $0.reference == detection.reference }) {
            detected.insert(detection, at: 0)
            // The likely reading goes up; any other reading of the same words
            // ("John 11" heard as 1:1) is loaded too, one click away.
            let shows = mode == .sermon && showsAutomatically
            Task { await prepare(detection.reference, thenShow: shows) }
            for alternative in detection.alternatives {
                Task { await prepare(alternative, thenShow: false) }
            }
        }
        if detected.count > 20 { detected.removeLast(detected.count - 20) }
    }

    func clearSermon() {
        sermonTranscript = ""
        detected = []
        prepared = [:]
    }

    /// Fetches and lays out the passage ahead of time.
    private func prepare(_ reference: BibleReference, thenShow: Bool) async {
        guard let model, prepared[reference.display] == nil else {
            if thenShow { try? await show(reference) }
            return
        }
        let settings = BibleSettings.shared
        if settings.translation == nil { await settings.refreshTranslations() }
        guard let translation = settings.translation,
              let passage = try? await settings.service.passage(reference, translation: translation)
        else { return }
        let themeID = model.slideBuilding.scriptureThemeId ?? ""
        await model.themesFilled([themeID])
        var presentation = ScriptureSlideBuilder.presentation(
            for: passage, format: settings.format, theme: model.theme(themeID))
        presentation.folder = "Sermon Scripture"
        prepared[reference.display] = presentation
        if thenShow { try? await show(reference) }
    }

    // MARK: Lyric following

    static func isSong(_ presentation: Presentation) -> Bool {
        presentation.presentationKind == .song || presentation.category == PresentationTypes.worship
    }

    func isFollowing(_ presentationID: String) -> Bool {
        followsEverySong || followedSongIDs.contains(presentationID)
    }

    /// Listening on the worship input, which is what following hears.
    var hearsWorship: Bool { listening && mode == .worship }

    /// Turns Follow on or off for one song; on starts listening if needed.
    func toggleFollow(_ presentation: Presentation) {
        if followedSongIDs.contains(presentation.id) {
            followedSongIDs.remove(presentation.id)
            DiagnosticsStore.shared.note("liveAssist.follow", detail: "off: \(presentation.name)")
            if suggestion?.presentationID == presentation.id, !isFollowing(presentation.id) { clearSuggestion() }
            stopIfNothingFollowed()
        } else {
            followedSongIDs.insert(presentation.id)
            DiagnosticsStore.shared.note("liveAssist.follow", detail: "on: \(presentation.name)")
            listenForLyrics()
        }
    }

    /// Starts the worship input if it isn't already what's being heard.
    func listenForLyrics() {
        guard !hearsWorship, !(starting && mode == .worship) else { return }
        listeningForFollow = true
        Task { await startWorship() }
    }

    private func stopIfNothingFollowed() {
        guard !followsEverySong, followedSongIDs.isEmpty, listeningForFollow, mode == .worship else { return }
        stop()
    }

    private func clearSuggestion() {
        if suggestion != nil { suggestion = nil }
        follower = nil
        followerKey = ""
        lastDecision = nil
        followPosition = nil
    }

    /// "6 Chorus": the slide's number and its group, else its first line.
    private func label(for index: Int, in slides: [Slide], of presentation: Presentation) -> String {
        let slide = slides[index]
        if let id = slide.sectionId, let name = presentation.sections?.first(where: { $0.id == id })?.name, !name.isEmpty {
            return "\(index + 1) \(name)"
        }
        let line = ConfidenceSceneBuilder.lyricText(for: slide)
            .split(separator: "\n").first.map { String($0.prefix(18)) } ?? ""
        return line.isEmpty ? "\(index + 1)" : "\(index + 1) \(line)"
    }

    private func follow(_ text: String, isFinal: Bool) {
        // Only a followed song that's live: never a deck, never anything else.
        guard let controls, let live = controls.state.liveSlide, let presentation = live.presentation,
              Self.isSong(presentation), isFollowing(presentation.id)
        else {
            if follower != nil { clearSuggestion() }
            return
        }
        let slides = SlideSceneBuilder.arrangedSlides(for: presentation, arrangementId: live.arrangementId)
        let texts = slides.map { ConfidenceSceneBuilder.lyricText(for: $0) }
        let occurrence = controls.liveOccurrence ?? slides.firstIndex { $0.id == live.slide.id } ?? 0
        let contextID = controls.liveContextID
        let key = "\(presentation.id)|\(live.arrangementId ?? "")|\(texts.hashValue)"
        let signature = "\(contextID ?? "")|\(occurrence)|\(live.slide.id)"
        if key != followerKey || follower == nil {
            followerKey = key
            follower = LyricFollower(slideTexts: texts, live: occurrence)
            liveSignature = signature
            landing = nil
        } else if signature != liveSignature {
            if let landing, signature == landing.from, Date() < landing.until {
                // Our advance hasn't landed yet; the follower is already there.
            } else {
                // Someone else moved the slide: listen from there, and hold off
                // unless it was the suggested slide.
                let accepted = suggestion.map { $0.slideIndex == occurrence && $0.contextID == contextID } ?? false
                liveSignature = signature
                landing = nil
                follower?.liveChanged(to: occurrence)
                if !accepted { takeOver() }
            }
        } else {
            landing = nil
        }
        guard var follower else { return }
        follower.hear(text, isFinal: isFinal)
        self.follower = follower
        lastDecision = follower.suggestion
        followPosition = follower.position

        if let made = follower.suggestion, slides.indices.contains(made.slideIndex) {
            let next = Suggestion(
                presentationID: presentation.id, contextID: contextID, fromOccurrence: follower.live,
                slideIndex: made.slideIndex, label: label(for: made.slideIndex, in: slides, of: presentation))
            if suggestion != next { suggestion = next }
            if abs(suggestionConfidence - made.confidence) >= 0.01 { suggestionConfidence = made.confidence }
        } else if suggestion != nil {
            suggestion = nil
        }

        guard advancesAutomatically, !isPaused,
              let decision = follower.decision, decision.confidence >= autoAdvanceConfidence,
              Date().timeIntervalSince(lastAutoFire) > 1.2,
              slides.indices.contains(decision.slideIndex)
        else { return }
        lastAutoFire = Date()
        landing = (from: liveSignature, until: Date().addingTimeInterval(3))
        liveSignature = "\(contextID ?? "")|\(decision.slideIndex)|\(slides[decision.slideIndex].id)"
        self.follower?.liveChanged(to: decision.slideIndex)
        suggestion = nil
        controls.fire(
            slide: slides[decision.slideIndex], in: presentation, arrangementId: live.arrangementId,
            contextID: contextID, occurrence: decision.slideIndex)
        DiagnosticsStore.shared.note(
            "liveAssist.follow.advance",
            detail: "\(presentation.name) \(occurrence + 1)→\(decision.slideIndex + 1) \(decision.reason) \(Int(decision.confidence * 100))%")
    }

    // MARK: Scripture

    /// Builds the passage with the Bible template and puts its first slide live.
    func show(_ reference: BibleReference) async throws {
        guard let model, let controls else { return }
        if let ready = prepared[reference.display] {
            if model.libraryEntry(ready.id) == nil { model.createInDrive(ready) }
            if let first = ready.slides.first { controls.fire(slide: first, in: ready) }
            return
        }
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
                        if assist.listening { assist.stop() } else { Task { await assist.startWorship() } }
                    }
                }
                Text(assist.transcript.isEmpty ? "…" : assist.transcript)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text("Lyric following and scripture detection options are in Settings › Show Setup.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("Lyric Follow") {
                Toggle("Follow every song", isOn: $assist.followsEverySong)
                Toggle("Advance automatically", isOn: $assist.advancesAutomatically)
                if !assist.followsEverySong {
                    Text("Or turn on Follow for one song in its slide grid header.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ConfidenceMeter(
                    decision: assist.lastDecision, label: assist.suggestion?.label,
                    threshold: assist.advancesAutomatically ? assist.autoAdvanceConfidence : nil)
                if let position = assist.followPosition {
                    Text("Heard: slide \(position.slideIndex + 1), word \(position.word) of \(position.wordCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Take Over (pause 8 s)") { assist.takeOver() }
                        .keyboardShortcut(.escape, modifiers: [])
                    if assist.isPaused { Text("Paused").font(.caption).foregroundStyle(.orange) }
                }
            }
            Section("Scripture Detection") {
                if assist.detected.isEmpty {
                    Text("When the pastor says “turn to Genesis 32”, it appears here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(assist.detected, id: \.self) { detection in
                    HStack {
                        ForEach([detection.reference] + detection.alternatives, id: \.self) { reference in
                            if reference != detection.reference { Text("or").foregroundStyle(.secondary) }
                            Button(reference.display) {
                                Task {
                                    do { try await assist.show(reference) } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                        Spacer()
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
    /// "6 Chorus".
    let label: String?
    /// Nil when it only suggests.
    let threshold: Double?

    var body: some View {
        let value = decision?.confidence ?? 0
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: value)
                .tint(threshold.map { value >= $0 } == true ? .green : value >= 0.4 ? .yellow : .gray)
            Text(text(value)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func text(_ value: Double) -> String {
        guard let decision else { return "Listening for the next line…" }
        let slide = label ?? "slide \(decision.slideIndex + 1)"
        let why = switch decision.reason {
        case .nextSlideStarted: "next slide started"
        case .currentSlideFinished: "last line sung"
        case .jump: "jumped"
        }
        return "Next: \(slide) — \(Int(value * 100))%, \(why)"
    }
}

/// Which microphone (and which channel of an interface) Live Assist hears,
/// with a level meter to confirm it.
struct LiveAssistInputPicker: View {
    var forSermon = false
    @Bindable private var assist = LiveAssist.shared
    @State private var devices = LiveTranscriber.inputDevices()

    private var device: Binding<String> { forSermon ? $assist.sermonDeviceUID : $assist.deviceUID }
    private var channel: Binding<Int?> { forSermon ? $assist.sermonChannel : $assist.channel }
    private var channels: Int { devices.first { $0.uid == device.wrappedValue }?.channels ?? 0 }

    var body: some View {
        Picker(forSermon ? "Pastor's mic" : "Listen to", selection: device) {
            if !devices.contains(where: { $0.uid == device.wrappedValue }) {
                Text("Choose a microphone…").tag(device.wrappedValue)
            }
            ForEach(devices, id: \.uid) { device in
                Text(device.channels > 2 ? "\(device.name) (\(device.channels) ch)" : device.name).tag(device.uid)
            }
        }
        .onAppear { devices = LiveTranscriber.inputDevices() }
        if channels > 1 {
            Picker("Channel", selection: channel) {
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

/// The Sermon tab: start listening to the pastor, see what's said, and put
/// any passage they mention on screen with one click.
struct SermonPanel: View {
    @Bindable private var assist = LiveAssist.shared
    @State private var error: String?

    private var sermonListening: Bool { assist.listening && assist.mode == .sermon }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if sermonListening { assist.stop() } else { Task { await assist.startSermon() } }
                } label: {
                    Label(sermonListening ? "Stop Listening" : "Listen to Sermon",
                          systemImage: sermonListening ? "mic.fill" : "mic")
                }
                .tint(sermonListening ? .red : nil)
                .buttonStyle(.borderedProminent)
                Spacer()
                if sermonListening {
                    ProgressView(value: Double(assist.level)).frame(width: 60).tint(.green)
                }
            }
            if !sermonListening, assist.mode == .sermon, assist.status != "Off" {
                Text(assist.status).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Microphone") { LiveAssistInputPicker(forSermon: true) }
                .font(.caption)
            Toggle("Show passages automatically", isOn: $assist.showsAutomatically)
                .font(.caption)
            Text("Mentioned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if assist.detected.isEmpty {
                Text("When a reference is said (“turn to Genesis 32”), it appears here, ready to show.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(assist.detected, id: \.self) { detection in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        ForEach([detection.reference] + detection.alternatives, id: \.self) { reference in
                            if reference != detection.reference {
                                Text("or").font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                Task {
                                    do { try await assist.show(reference) } catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(reference.display)
                                    if assist.prepared[reference.display] != nil {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    }
                                }
                            }
                            .controlSize(.small)
                            .fontWeight(reference == detection.reference ? .semibold : .regular)
                            .help(reference == detection.reference
                                  ? "Most likely reading — shown automatically"
                                  : "Show \(reference.display) instead")
                        }
                        Spacer()
                    }
                    if detection.ambiguous {
                        Text("Could also be \(detection.alternatives.map(\.display).joined(separator: " or ")). Click it if that's what was meant.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(assist.sermonTranscript.isEmpty ? "…" : assist.sermonTranscript)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .frame(minHeight: 120)
                .onChange(of: assist.sermonTranscript) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if !assist.sermonTranscript.isEmpty || !assist.detected.isEmpty {
                Button("Clear") { assist.clearSermon() }.controlSize(.small)
            }
        }
    }
}
