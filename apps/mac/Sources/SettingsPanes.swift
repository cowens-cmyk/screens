import AVFoundation
import MediaEngine
import AudioEngine
import NDIKit
import PresenterCore
import SwiftUI

// MARK: - Slides & Themes

/// Settings › Slides & Themes: transitions, default animations and how the
/// slide grid draws its thumbnails.
struct SlidesSettingsPane: View {
    let model: AppModel?

    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.transparencyGrid") private var transparencyGrid = true
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback

    var body: some View {
        Form {
            Section {
                SettingsRow("present.slideTransition") {
                    DefaultTransitionControl(
                        kindKey: "transition.slide.kind", durationKey: "transition.slide.duration",
                        fallbackKind: "", fallbackDuration: 0.5)
                }
                SettingsRow("present.mediaTransition") {
                    DefaultTransitionControl(
                        kindKey: "transition.media.kind", durationKey: "transition.media.duration",
                        fallbackKind: TransitionKind.dissolve.rawValue, fallbackDuration: 0.7)
                }
            } header: {
                Text("Transitions")
            } footer: {
                Text("A slide or item can set its own. The footer chips change the media transition on the fly.")
            }
            if model != nil {
                Section {
                    SettingsRow("present.defaultAnimations") {
                        DefaultAnimationsControl(model: model)
                    }
                } header: {
                    Text("Animations")
                } footer: {
                    Text("A preset's Set as Default In or Out changes these too.")
                }
            }
            Section {
                SettingsRow("present.slidesAcross") {
                    SlidesAcrossControl(count: $slidesAcross).frame(width: 200)
                }
                SettingsToggle("present.roundedCorners", isOn: $roundedCorners)
                SettingsToggle("present.legibleText", isOn: $legibleText)
                SettingsToggle("present.transparencyGrid", isOn: $transparencyGrid)
                SettingsToggle("present.scopedBackgrounds", isOn: $hideScopedBackgrounds)
            } header: {
                Text("Slide Grid")
            }
        }
        .settingsForm()
    }
}

// MARK: - Media & Video

/// Settings › Media & Video: the cameras, NDI sources, web pages and audio
/// interfaces Live Input objects and Live Assist use. Each opens its own
/// page here, with a way back.
struct MediaSettingsPane: View {
    enum Page: Equatable {
        case list
        case videoInput(String)
        case audioInput(String)
    }

    @State private var page: Page = .list

    var body: some View {
        VStack(spacing: 0) {
            if page != .list {
                SettingsPageHeader(backTitle: SettingsCategory.media.title, title: pageTitle) { page = .list }
                Divider()
            }
            switch page {
            case .list:
                Form {
                    VideoInputsSection { page = .videoInput($0) }
                    AudioInputsSection { page = .audioInput($0) }
                }
                .settingsForm()
            case .videoInput(let id):
                VideoInputDetail(id: id) { page = .list }
            case .audioInput(let id):
                AudioInputDetail(id: id) { page = .list }
            }
        }
        .background(Color.basePlane)
    }

    private var pageTitle: String {
        switch page {
        case .list: SettingsCategory.media.title
        case .videoInput(let id): VideoInputInventory.shared.entries.first { $0.id == id }?.name ?? "Video Input"
        case .audioInput(let id): AudioInputInventory.shared.entries.first { $0.id == id }?.name ?? "Audio Input"
        }
    }
}

// MARK: - Integrations

/// Settings › Integrations: Anthem, Lightkey and MIDI, Shepherd, and the
/// phone remote and Local API, one at a time.
struct IntegrationsSettingsPane: View {
    let model: AppModel?
    let api: LocalAPIController?
    @Binding var tab: IntegrationTab

    @State private var midiDevice: String?

    var body: some View {
        VStack(spacing: 0) {
            if let midiDevice {
                SettingsPageHeader(
                    backTitle: IntegrationTab.lightkey.title,
                    title: MIDIDeviceInventory.shared.items.first { $0.id == midiDevice }?.device.name ?? "MIDI Device"
                ) { self.midiDevice = nil }
                Divider()
                MIDIDeviceDetail(id: midiDevice) { self.midiDevice = nil }
            } else {
                Picker("", selection: $tab) {
                    ForEach(IntegrationTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 16)
                .padding(.bottom, 4)
                content
                    .id(tab)
            }
        }
        .background(Color.basePlane)
        .onChange(of: tab) { _, _ in midiDevice = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .anthem:
            Form { AnthemSettingsForm() }
                .settingsForm()
        case .lightkey:
            Form {
                LightkeySettingsForm(model: model)
                MIDIDevicesSection { midiDevice = $0 }
                Section {
                    SettingsRow("midi.map") { MIDIMapManager() }
                } header: {
                    Text("MIDI Input Map")
                }
            }
            .settingsForm()
        case .shepherd:
            Form { ShepherdSettingsForm() }
                .settingsForm()
        case .remote:
            if let api {
                LocalAPISettingsForm(api: api)
            } else {
                SettingsUnavailable(text: "The Local API isn't available.")
            }
        }
    }
}

/// Integrations › Remote & API.
private struct LocalAPISettingsForm: View {
    let api: LocalAPIController

    var body: some View {
        Form {
            Section {
                SettingsRow("api.enabled") { LocalAPIEnableToggle(api: api) }
                SettingsRow("api.port") { LocalAPIPortField(api: api) }
                SettingsRow("api.address") { LocalAPIAddressRow(api: api) }
            } header: {
                Text("Local API")
            }
            Section {
                LocalAPIRemoteQRRow(api: api)
                    .padding(.vertical, 4)
            } header: {
                SettingsHeader(id: "api.remote")
            } footer: {
                Text(SettingsIndex.entry("api.remote")?.caption ?? "")
            }
            Section {
                SettingsRow("api.tokens") { LocalAPITokensButton(api: api) }
                SettingsRow("api.docs") { LocalAPIContractRow(api: api) }
            } header: {
                Text("Access")
            }
        }
        .settingsForm()
    }
}

// MARK: - Advanced

/// Settings › Advanced: updates and the diagnostics log.
struct AdvancedSettingsPane: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section {
                SettingsToggle("advanced.updates", isOn: $updater.checksAutomatically)
                LabeledContent("Version") {
                    HStack(spacing: 12) {
                        Text(updater.currentVersion)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button(updater.isWorking ? "Checking…" : "Check Now") {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.isWorking)
                    }
                }
                if let status = updater.status {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Turning automatic checks on or off takes effect the next time Screens opens.")
            }
            Section {
                SettingsRow("advanced.diagnostics") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsStore.folder])
                    }
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .settingsForm()
    }
}

// MARK: - Inputs

private struct VideoInputsSection: View {
    let open: (String) -> Void
    @State private var inventory = VideoInputInventory.shared
    @State private var discoveredNDI: [String] = []
    @State private var ndiRuntimeAvailable = true
    @State private var addingNDI = false
    @State private var ndiName = ""
    @State private var addingWeb = false
    @State private var decklink = DeckLinkInputCatalog.shared

    var body: some View {
        Section {
            if inventory.entries.isEmpty {
                Text("No video inputs yet.").foregroundStyle(.secondary)
            }
            ForEach(inventory.entries) { entry in
                Button { open(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: VideoInputWords.symbol(entry))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13))
                            Text(VideoInputWords.device(entry))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Input\u{2026}") {
                Button("Empty Input — assign a device later") { inventory.create(name: VideoInputWords.newName(inventory)) }
                Section("Cameras") {
                    ForEach(VideoInputWords.discoverableCameras(inventory), id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            inventory.create(name: device.localizedName, kind: .camera, sourceId: device.uniqueID)
                        }
                    }
                }
                Section("NDI Sources") {
                    ForEach(addableNDI, id: \.self) { name in
                        Button(name) { inventory.create(name: name, kind: .ndi, sourceId: name) }
                    }
                    if !ndiRuntimeAvailable {
                        Text("NDI unavailable — runtime missing from this build")
                    } else if addableNDI.isEmpty {
                        Text("Searching the network\u{2026}")
                    }
                }
                Divider()
                Button("NDI Source by Name\u{2026}") { addingNDI = true }
                Button("Web Page\u{2026}") { addingWeb = true }
                Menu("DeckLink Input\u{2026}") {
                    ForEach(decklink.ports) { port in
                        Button(VideoInputWords.decklinkPortLabel(port)) {
                            inventory.create(name: port.name, kind: .decklink, sourceId: String(port.persistentID))
                        }
                        .disabled(!port.usableForCapture)
                    }
                    if let reason = decklink.emptyReason {
                        Text(reason)
                    }
                }
            }
            .fixedSize()
        } header: {
            SettingsHeader(id: "avInputs.cameras")
        } footer: {
            Text(SettingsIndex.entry("avInputs.cameras")?.caption ?? "")
        }
        .task {
            while !Task.isCancelled {
                decklink.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .task {
            while !Task.isCancelled {
                let names = await Task.detached(priority: .utility) { () -> [String]? in
                    guard let library = try? NDILibrary.load(), let finder = NDIFinder(library: library) else { return nil }
                    return finder.currentSourceNames(wait: 1500)
                }.value
                ndiRuntimeAvailable = names != nil
                discoveredNDI = names ?? []
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .sheet(isPresented: $addingWeb) {
            WebInputSheet(title: "Add Web Page", confirm: "Add") { choice in
                inventory.createWeb(
                    name: choice.name, url: choice.url, width: choice.width,
                    height: choice.height, frameRate: choice.frameRate)
            }
        }
        .alert("NDI Source by Name", isPresented: $addingNDI) {
            TextField("Source name (or part of it)", text: $ndiName)
            Button("Add") {
                let trimmed = ndiName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { inventory.create(name: trimmed, kind: .ndi, sourceId: trimmed) }
                ndiName = ""
            }
            Button("Cancel", role: .cancel) { ndiName = "" }
        } message: {
            Text("The input connects to the first NDI source whose name contains this text — and keeps watching for it, so boot order never matters.")
        }
    }

    private var addableNDI: [String] {
        let fragments = inventory.entries.filter { $0.kind == .ndi }.compactMap(\.sourceId)
        return discoveredNDI.filter { name in !fragments.contains { name.localizedCaseInsensitiveContains($0) } }
    }
}

@MainActor
private enum VideoInputWords {
    static func device(_ entry: VideoInputInventory.Entry) -> String {
        guard let sourceId = entry.sourceId, !sourceId.isEmpty, let kind = entry.kind else { return "No device" }
        if kind == .ndi { return "NDI \u{B7} \(sourceId)" }
        if kind == .web { return "Web \u{B7} \(WebInputURL.normalized(sourceId)?.host() ?? sourceId)" }
        if kind == .decklink {
            let port = DeckLinkInputCatalog.shared.port(id: sourceId)?.name ?? "Port \(sourceId)"
            guard let state = VideoInputInventory.shared.decklinkState(id: entry.id) else { return "DeckLink \u{B7} \(port)" }
            return "DeckLink \u{B7} \(port) \u{B7} \(state.text)"
        }
        return AVCaptureDevice(uniqueID: sourceId)?.localizedName ?? "Missing camera"
    }

    static func symbol(_ entry: VideoInputInventory.Entry) -> String {
        switch entry.kind {
        case .ndi: return "network"
        case .web: return "globe"
        case .decklink: return "rectangle.connected.to.line.below"
        case .camera, nil: return "video"
        }
    }

    static func decklinkPortLabel(_ port: DeckLinkHelperInputDevice) -> String {
        if !port.usableForCapture { return "\(port.name) \u{2014} mapped as output" }
        if port.playbackBusy { return "\(port.name) \u{2014} in use for output" }
        return port.name
    }

    static func webStatus(_ source: WebInputSource?) -> String {
        guard let source else { return "Not running" }
        let text = WebInputSource.statusText(
            source.state, width: source.width, height: source.height, fps: source.framesPerSecond)
        if source.state == .capturing, !source.isReceiving { return text + " \u{2014} waiting for the page" }
        return text
    }

    static func newName(_ inventory: VideoInputInventory) -> String {
        let existing = Set(inventory.entries.map(\.name))
        var number = inventory.entries.count + 1
        while existing.contains("Input \(number)") { number += 1 }
        return "Input \(number)"
    }

    static var allCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.localizedName.localizedCaseInsensitiveContains("NDI Virtual") }
    }

    static func discoverableCameras(_ inventory: VideoInputInventory) -> [AVCaptureDevice] {
        let assigned = Set(inventory.entries.filter { $0.kind == .camera }.compactMap(\.sourceId))
        return allCameras.filter { !assigned.contains($0.uniqueID) }
    }
}

private struct VideoInputDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = VideoInputInventory.shared
    @State private var audioInventory = AudioInputInventory.shared
    @State private var discoveredNDI: [String] = []
    @State private var addingNDI = false
    @State private var ndiName = ""
    @State private var confirmRemove = false
    @State private var assigningWeb = false
    @State private var webURL = ""
    @State private var decklink = DeckLinkInputCatalog.shared

    @State private var frameRates: [Double] = []

    var body: some View {
        if let entry = inventory.entries.first(where: { $0.id == id }) {
            Form {
                Section("Input") {
                    TextField("Name", text: Binding(get: { entry.name }, set: { inventory.rename(id: id, to: $0) }))
                    Picker("Device", selection: Binding(
                        get: { deviceTag(entry) },
                        set: { tag in
                            if tag == "" { inventory.assignDevice(id: id, kind: nil, sourceId: nil) }
                            else if tag.hasPrefix("ndi:") { inventory.assignDevice(id: id, kind: .ndi, sourceId: String(tag.dropFirst(4))) }
                            else if tag == "ndi-by-name" { addingNDI = true }
                            else if tag == "web-new" { assigningWeb = true }
                            else if tag.hasPrefix("decklink:") {
                                let port = String(tag.dropFirst("decklink:".count))
                                guard entry.kind != .decklink || entry.sourceId != port else { return }
                                inventory.assignDevice(id: id, kind: .decklink, sourceId: port)
                            }
                            else if tag.hasPrefix("web:") { return }
                            else { inventory.assignDevice(id: id, kind: .camera, sourceId: tag) }
                        })
                    ) {
                        Text("No device").tag("")
                        Section("Cameras") {
                            ForEach(VideoInputWords.allCameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        Section("NDI Sources") {
                            ForEach(discoveredNDI, id: \.self) { Text($0).tag("ndi:\($0)") }
                            if let sourceId = entry.sourceId, entry.kind == .ndi, !discoveredNDI.contains(sourceId) {
                                Text("NDI \u{B7} \(sourceId) (not on the network)").tag("ndi:\(sourceId)")
                            }
                            Text("NDI Source by Name\u{2026}").tag("ndi-by-name")
                        }
                        Section("Web") {
                            if let sourceId = entry.sourceId, entry.kind == .web {
                                Text(VideoInputWords.device(entry)).tag("web:\(sourceId)")
                            }
                            Text("Web Page\u{2026}").tag("web-new")
                        }
                        Section("DeckLink") {
                            ForEach(decklink.capturePorts) { Text($0.name).tag("decklink:\($0.persistentID)") }
                            if let sourceId = entry.sourceId, entry.kind == .decklink,
                               !decklink.capturePorts.contains(where: { String($0.persistentID) == sourceId }) {
                                Text("\(decklink.port(id: sourceId)?.name ?? "DeckLink port \(sourceId)") (not available)")
                                    .tag("decklink:\(sourceId)")
                            }
                        }
                    }
                    if entry.kind == .decklink {
                        LabeledContent("Signal") {
                            let state = inventory.decklinkState(id: id)
                            Text(state?.text ?? "Not running")
                                .foregroundStyle(Self.decklinkColor(state))
                        }
                    }
                    if entry.kind == .web {
                        TextField("Web address", text: $webURL)
                            .onSubmit {
                                guard let url = WebInputURL.normalized(webURL) else { return }
                                inventory.assignDevice(id: id, kind: .web, sourceId: url.absoluteString)
                            }
                            .onAppear { webURL = entry.sourceId ?? "" }
                            .onChange(of: entry.sourceId) { _, url in webURL = url ?? "" }
                        Picker("Resolution", selection: Binding(
                            get: { VideoInputInventory.webSize(entry).height },
                            set: { inventory.setWebResolution(id: id, width: $0 * 16 / 9, height: $0) })
                        ) {
                            ForEach(WebInputSheet.heights, id: \.self) { Text(WebInputSheet.resolutionLabel($0)).tag($0) }
                        }
                        Picker("Frame rate", selection: Binding(
                            get: { VideoInputInventory.webSize(entry).fps },
                            set: { inventory.setFrameRate(id: id, rate: Double($0)) })
                        ) {
                            ForEach(WebInputSheet.rates, id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        Toggle("Mute page audio", isOn: Binding(
                            get: { entry.pageMuted ?? false },
                            set: { inventory.setPageMuted(id: id, muted: $0) }))
                        LabeledContent("Status") {
                            let source = inventory.webSource(id: id)
                            HStack(spacing: 8) {
                                Text(VideoInputWords.webStatus(source))
                                    .foregroundStyle(source?.state == .needsPermission ? Color.orange : Color.secondary)
                                if source?.state == .needsPermission {
                                    Button("Open Settings") { WebInputURL.openScreenRecordingSettings() }
                                }
                            }
                        }
                        Button("Show Web Input Window") { inventory.showWebWindow(id: id) }
                    }
                    Picker("Audio input", selection: Binding(
                        get: { entry.audioInputId ?? "" },
                        set: { inventory.assignAudioInput(id: id, audioInputId: $0.isEmpty ? nil : $0) })
                    ) {
                        Text("None").tag("")
                        ForEach(audioInventory.entries) { Text($0.name).tag($0.id) }
                    }
                    if entry.kind == .camera, !frameRates.isEmpty {
                        Picker("Frame rate", selection: Binding(
                            get: { entry.frameRate ?? 0 },
                            set: { inventory.setFrameRate(id: id, rate: $0 == 0 ? nil : $0) })
                        ) {
                            Text("Auto").tag(0.0)
                            ForEach(frameRates, id: \.self) {
                                Text(String(format: "%g fps", $0)).tag($0)
                            }
                            if let rate = entry.frameRate, !frameRates.contains(rate) {
                                Text(String(format: "%g fps (not offered)", rate)).tag(rate)
                            }
                        }
                    }
                    LabeledContent("Video delay") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { entry.delayFrames ?? 0 },
                                set: { inventory.setDelay(id: id, frames: min(max($0, 0), LiveInputDelay.maxFrames)) }),
                                format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 48)
                            Text("frames").foregroundStyle(.secondary)
                            Stepper("", value: Binding(
                                get: { entry.delayFrames ?? 0 },
                                set: { inventory.setDelay(id: id, frames: $0) }),
                                in: 0...LiveInputDelay.maxFrames).labelsHidden()
                        }
                    }
                }
                Section {
                    Button("Remove Input\u{2026}", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removing stops its capture; slides using it render empty. The audio input plays with it while it is on screen; video delay holds the picture back to match late audio. Frame rate is the capture device's mode, from the rates the device offers: Auto takes 30; pick the one nearest your source when it runs faster (60 for a 59.94 camera). Inputs on the same device share it.")
                    if entry.kind == .decklink {
                        Text("A DeckLink input captures one port of the card and follows the incoming format automatically (an Apple TV or other HDMI source needs an HDMI\u{2192}SDI converter on SDI-only cards). Only ports mapped as inputs in Desktop Video Setup can capture; a port that is driving a DeckLink screen output can't.")
                    }
                    if entry.kind == .web {
                        Text("A web page input records its Web Input window with Screen Recording, so keep that window open on a display (it can sit behind other windows) and use it to click play, scroll or sign in. Page audio plays from this Mac's sound output. For a full-frame video, use the player's embed address (youtube.com/embed/\u{2026}).")
                    }
                }
            }
            .settingsForm()
            .task(id: entry.kind == .camera ? entry.sourceId : nil) {
                let sourceId = entry.kind == .camera ? entry.sourceId : nil
                frameRates = await Task.detached(priority: .utility) {
                    sourceId.flatMap { AVCaptureDevice(uniqueID: $0) }
                        .map { MediaEngine.captureFrameRates(for: $0) } ?? []
                }.value
            }
            .task { decklink.refresh() }
            .task {
                while !Task.isCancelled {
                    let names = await Task.detached(priority: .utility) { () -> [String]? in
                        guard let library = try? NDILibrary.load(), let finder = NDIFinder(library: library) else { return nil }
                        return finder.currentSourceNames(wait: 1500)
                    }.value
                    discoveredNDI = names ?? []
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .alert("NDI Source by Name", isPresented: $addingNDI) {
                TextField("Source name (or part of it)", text: $ndiName)
                Button("Assign") {
                    let trimmed = ndiName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { inventory.assignDevice(id: id, kind: .ndi, sourceId: trimmed) }
                    ndiName = ""
                }
                Button("Cancel", role: .cancel) { ndiName = "" }
            }
            .sheet(isPresented: $assigningWeb) {
                WebInputSheet(title: "Web Page", confirm: "Assign", name: entry.name) { choice in
                    inventory.assignWeb(
                        id: id, url: choice.url, width: choice.width, height: choice.height,
                        frameRate: choice.frameRate)
                }
            }
            .alert("Remove \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(entry); back() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Input not found", systemImage: "video")
        }
    }

    private static func decklinkColor(_ state: DeckLinkInputClient.State?) -> Color {
        switch state {
        case .receiving: .green
        case .failed: .orange
        case .noSignal, .starting, nil: .secondary
        }
    }

    private func deviceTag(_ entry: VideoInputInventory.Entry) -> String {
        guard let sourceId = entry.sourceId, !sourceId.isEmpty, let kind = entry.kind else { return "" }
        switch kind {
        case .ndi: return "ndi:\(sourceId)"
        case .web: return "web:\(sourceId)"
        case .decklink: return "decklink:\(sourceId)"
        case .camera: return sourceId
        }
    }
}

// Collects a Web Page input's address, output size and rate — for adding one or reassigning an input.
private struct WebInputSheet: View {
    struct Choice {
        var name: String
        var url: String
        var width: Int
        var height: Int
        var frameRate: Double
    }

    static let heights = [1080, 720]
    static let rates = [30, 60]

    static func resolutionLabel(_ height: Int) -> String {
        "\(height * 16 / 9)\u{D7}\(height)"
    }

    let title: String
    let confirm: String
    var name: String? = nil
    let done: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var height = 1080
    @State private var rate = 30

    private var normalized: URL? { WebInputURL.normalized(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                TextField("Web address", text: $url, prompt: Text("https://example.com"))
                Picker("Resolution", selection: $height) {
                    ForEach(Self.heights, id: \.self) { Text(Self.resolutionLabel($0)).tag($0) }
                }
                Picker("Frame rate", selection: $rate) {
                    ForEach(Self.rates, id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            Text("The page opens in its own Web Input window \u{2014} click, scroll and sign in there. Capturing it needs Screen Recording permission.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm) {
                    guard let normalized else { return }
                    done(Choice(
                        name: name ?? normalized.host() ?? "Web Page",
                        url: normalized.absoluteString, width: height * 16 / 9, height: height,
                        frameRate: Double(rate)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalized == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct AudioInputsSection: View {
    let open: (String) -> Void
    @State private var inventory = AudioInputInventory.shared
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []
    @State private var channelPickerDevice: AudioDeviceList.AudioInputDevice?

    var body: some View {
        Section {
            if inventory.entries.isEmpty {
                Text("No audio inputs yet.").foregroundStyle(.secondary)
            }
            ForEach(inventory.entries) { entry in
                Button { open(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13))
                            Text(AudioInputWords.subtitle(entry, devices: devices))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if entry.isAssigned, AudioDeviceList.inputDevice(uid: entry.uid ?? "") == nil {
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Input\u{2026}") {
                Button("Empty Input — assign a device later") { inventory.create(name: AudioInputWords.newName(inventory)) }
                ForEach(devices, id: \.uid) { device in
                    if device.channelCount > 2 {
                        Button("\(AudioInputWords.deviceLabel(device)) — pick channels\u{2026}") { channelPickerDevice = device }
                    } else {
                        Button(AudioInputWords.deviceLabel(device)) { inventory.create(name: device.name, uid: device.uid) }
                    }
                }
                if devices.isEmpty { Text("No input devices") }
            }
            .fixedSize()
        } header: {
            SettingsHeader(id: "avInputs.audio")
        } footer: {
            Text(SettingsIndex.entry("avInputs.audio")?.caption ?? "")
        }
        .sheet(item: $channelPickerDevice) { AudioChannelPickerSheet(device: $0) }
        .task {
            while !Task.isCancelled {
                devices = AudioDeviceList.inputDevices()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

@MainActor
private enum AudioInputWords {
    static func subtitle(_ entry: AudioInputInventory.Entry, devices: [AudioDeviceList.AudioInputDevice]) -> String {
        guard let uid = entry.uid, !uid.isEmpty else { return "No device" }
        guard let device = AudioDeviceList.inputDevice(uid: uid) else { return "Missing device" }
        var parts = [device.name]
        if device.channelCount > 1 { parts.append(channels(entry)) }
        if let ms = entry.delayMs, ms > 0 { parts.append("\(ms) ms delay") }
        return parts.joined(separator: " \u{B7} ")
    }

    static func channels(_ entry: AudioInputInventory.Entry) -> String {
        let numbers = switch entry.channels {
        case .stereoPair(let offset): "Stereo \(offset + 1)-\(offset + 2)"
        case .mono(let channel): "Mono \(channel + 1)"
        }
        return numbers + AudioChannelNameStore.shared.suffix(uid: entry.uid, selection: entry.channels)
    }

    static func newName(_ inventory: AudioInputInventory) -> String {
        let existing = Set(inventory.entries.map(\.name))
        var number = inventory.entries.count + 1
        while existing.contains("Audio Input \(number)") { number += 1 }
        return "Audio Input \(number)"
    }

    static func deviceLabel(_ device: AudioDeviceList.AudioInputDevice) -> String {
        device.channelCount > 2 ? "\(device.name) (\(device.channelCount) ch)" : device.name
    }
}

private struct AudioInputDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = AudioInputInventory.shared
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []
    @State private var confirmRemove = false

    var body: some View {
        if let entry = inventory.entries.first(where: { $0.id == id }) {
            let device = AudioDeviceList.inputDevice(uid: entry.uid ?? "")
            Form {
                Section("Input") {
                    TextField("Name", text: Binding(get: { entry.name }, set: { inventory.rename(id: id, to: $0) }))
                    Picker("Device", selection: Binding(
                        get: { entry.uid ?? "" },
                        set: { inventory.assignDevice(id: id, uid: $0.isEmpty ? nil : $0) })
                    ) {
                        Text("No device").tag("")
                        ForEach(devices, id: \.uid) { Text(AudioInputWords.deviceLabel($0)).tag($0.uid) }
                        if let uid = entry.uid, !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
                            Text("Missing device (not connected)").tag(uid)
                        }
                    }
                    if let device, device.channelCount > 1 {
                        Picker("Channels", selection: Binding(
                            get: { channelTag(entry) },
                            set: { tag in
                                if tag.hasPrefix("s") { inventory.assignChannels(id: id, channelOffset: Int(tag.dropFirst()) ?? 0, monoChannel: nil) }
                                else { inventory.assignChannels(id: id, channelOffset: nil, monoChannel: Int(tag.dropFirst()) ?? 0) }
                            })
                        ) {
                            let names = AudioChannelNameStore.shared
                            ForEach(Array(stride(from: 0, to: max(2, device.channelCount) - 1, by: 2)), id: \.self) { offset in
                                Text("Stereo \(offset + 1)-\(offset + 2)" + names.suffix(uid: device.uid, selection: .stereoPair(offset: offset))).tag("s\(offset)")
                            }
                            Divider()
                            ForEach(0..<device.channelCount, id: \.self) { channel in
                                Text("Mono \(channel + 1)" + names.suffix(uid: device.uid, selection: .mono(channel: channel))).tag("m\(channel)")
                            }
                        }
                    }
                    LabeledContent("Audio delay") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: min(max($0, 0), 2000)) }),
                                format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 56)
                            Text("ms").foregroundStyle(.secondary)
                            Stepper("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: $0) }),
                                in: 0...2000, step: 5).labelsHidden()
                        }
                    }
                }
                Section {
                    Button("Remove Input\u{2026}", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Delay holds this input's audio back to match late video.")
                }
            }
            .settingsForm()
            .task {
                while !Task.isCancelled {
                    devices = AudioDeviceList.inputDevices()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .alert("Remove \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(entry); back() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Input not found", systemImage: "mic")
        }
    }

    private func channelTag(_ entry: AudioInputInventory.Entry) -> String {
        switch entry.channels {
        case .stereoPair(let offset): "s\(offset)"
        case .mono(let channel): "m\(channel)"
        }
    }
}

private struct MIDIDevicesSection: View {
    let open: (String) -> Void
    @State private var inventory = MIDIDeviceInventory.shared

    var body: some View {
        Section {
            if inventory.items.isEmpty {
                Text("No devices added — MIDI Out reaches every destination on this Mac.").foregroundStyle(.secondary)
            }
            ForEach(inventory.items) { item in
                Button { open(item.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "pianokeys").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.device.name).font(.system(size: 13))
                                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                            Text(item.effectiveDirection.displayName + (item.isEnabled ? "" : " \u{B7} Off"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.isConnected(
                            destinations: Set(inventory.discoveredDestinations.map(\.uid)),
                            sources: Set(inventory.discoveredSources.map(\.uid))) {
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Device\u{2026}") {
                ForEach(addableDevices) { device in
                    Button(device.name) { inventory.add(discovered: device) }
                }
                if addableDevices.isEmpty { Text("No other MIDI devices") }
            }
            .fixedSize()
        } header: {
            SettingsHeader(id: "midi.devices")
        } footer: {
            Text(SettingsIndex.entry("midi.devices")?.caption ?? "")
        }
        .task { inventory.reload() }
    }

    private var addableDevices: [MIDIDeviceEntry] {
        let claimedOut = Set(inventory.items.compactMap(\.destinationUID))
        let claimedIn = Set(inventory.items.compactMap(\.sourceUID))
        return inventory.discoveredDevices.filter {
            !claimedOut.contains($0.uid) && !($0.sourceUid.map(claimedIn.contains) ?? false)
        }
    }
}

private struct MIDIDeviceDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = MIDIDeviceInventory.shared
    @State private var confirmRemove = false

    var body: some View {
        if let item = inventory.items.first(where: { $0.id == id }) {
            Form {
                Section("Device") {
                    Toggle("Enabled", isOn: Binding(get: { item.isEnabled }, set: { inventory.setEnabled(item, enabled: $0) }))
                    Picker("Direction", selection: Binding(
                        get: { item.effectiveDirection },
                        set: { inventory.setDirection(item, direction: $0) })
                    ) {
                        ForEach(MIDIDeviceItemDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    if item.wantsOutput {
                        portPicker("Out port", bound: item.destinationUID, endpoints: inventory.discoveredDestinations) {
                            inventory.setDestinationBinding(item, uid: $0)
                        }
                    }
                    if item.wantsInput {
                        portPicker("In port", bound: item.sourceUID, endpoints: inventory.discoveredSources) {
                            inventory.setSourceBinding(item, uid: $0)
                        }
                        Picker("Channel", selection: Binding(
                            get: { item.device.channel ?? 0 },
                            set: { inventory.setChannel(item, channel: $0 == 0 ? nil : $0) })
                        ) {
                            Text("Any channel").tag(0)
                            ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                        }
                    }
                } header: {
                    Text("Ports on this Mac")
                } footer: {
                    Text("Automatic matches ports by name, so an imported rig lights up wherever its ports live. Channel filters which incoming notes trigger commands.")
                }
                Section {
                    Button("Remove Device\u{2026}", role: .destructive) { confirmRemove = true }
                }
            }
            .settingsForm()
            .alert("Remove \u{201C}\(item.device.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(item); back() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The device is a library item — combos and imports referencing it lose their target. With none left, MIDI Out reaches every destination again.")
            }
        } else {
            ContentUnavailableView("Device not found", systemImage: "pianokeys")
        }
    }

    private func portPicker(_ label: String, bound: Int32?, endpoints: [MIDIEndpoint], pin: @escaping (Int32?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { bound ?? 0 }, set: { pin($0 == 0 ? nil : $0) })) {
            Text("Automatic (match by name)").tag(Int32(0))
            ForEach(endpoints, id: \.uid) { Text($0.name).tag($0.uid) }
            if let bound, !endpoints.contains(where: { $0.uid == bound }) {
                Text("Port not present").tag(bound)
            }
        }
    }
}
