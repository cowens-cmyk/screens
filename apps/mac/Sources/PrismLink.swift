import CoreMIDI
import Foundation
import Observation
import PresenterCore
import SwiftUI

/// Prism, the church's lighting app, listens to Screens by MIDI note. On
/// this Mac it hears the "Screens" MIDI source by itself; on another Mac,
/// Screens joins that Mac's network MIDI session (Prism turns its session
/// on and lets anyone in), so cues travel over the LAN.
///
/// Prism's scenes come from its show file on this Mac, so a slide's
/// right-click › Prism lists them by name.
@MainActor
@Observable
final class PrismLink {
    static let shared = PrismLink()

    enum Location: String, CaseIterable, Identifiable {
        case thisMac, network
        var id: String { rawValue }
        var title: String { self == .thisMac ? "This Mac" : "Another Mac on the network" }
    }

    var location: Location {
        didSet {
            save()
            // Picking the same place again shouldn't drop a live connection.
            if location != oldValue { apply() }
        }
    }
    var host: String { didSet { save() } }
    var port: Int { didSet { save() } }
    /// Prism listens on one channel (16 unless changed there), so a
    /// keyboard on another channel can't change the lights.
    var channel: Int { didSet { save() } }

    /// Changes Prism's scene as the service moves: each plan item sends
    /// its position's note (Walk-in, Song 1, Message…) when it goes live.
    /// Per Mac, like the rest of this link; the note table is the church's.
    /// Off until someone turns it on here, so a second Mac running a plan
    /// doesn't change the room's lights.
    var followsService: Bool { didSet { save() } }

    private(set) var status = ""

    /// Prism's scenes, from its show on this Mac; empty when Prism has never
    /// run here.
    private(set) var prismScenes: [PrismScene] = []

    private var connection: MIDINetworkConnection?
    private var watcher: DispatchSourceFileSystemObject?

    private init() {
        let defaults = UserDefaults.standard
        location = Self.stored("location", defaults).flatMap { ($0 as? String).flatMap(Location.init(rawValue:)) } ?? .thisMac
        host = Self.stored("host", defaults) as? String ?? ""
        port = Self.stored("port", defaults) as? Int ?? 5004
        channel = Self.stored("channel", defaults) as? Int ?? 16
        followsService = Self.stored("followService", defaults) as? Bool ?? false
        // Settings saved before this link was Prism's sat under the old
        // lighting app's prefix; they move over once.
        for key in ["location", "host", "port", "channel", "followService", "sections"] {
            defaults.removeObject(forKey: Self.olderPrefix + key)
        }
        save()
    }

    private static let prefix = "prism."
    private static let olderPrefix = "lightkey."

    private static func stored(_ key: String, _ defaults: UserDefaults) -> Any? {
        defaults.object(forKey: prefix + key) ?? defaults.object(forKey: olderPrefix + key)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(location.rawValue, forKey: Self.prefix + "location")
        defaults.set(host, forKey: Self.prefix + "host")
        defaults.set(port, forKey: Self.prefix + "port")
        defaults.set(channel, forKey: Self.prefix + "channel")
        defaults.set(followsService, forKey: Self.prefix + "followService")
    }

    func start() {
        MIDIOutService.shared.prepare()
        apply()
        loadScenes()
    }

    /// Joins (or leaves) the network MIDI session and connects to the
    /// Prism Mac's session.
    func apply() {
        let session = MIDINetworkSession.default()
        if let connection {
            session.removeConnection(connection)
            self.connection = nil
        }
        guard location == .network else {
            status = "Prism on this Mac hears Screens by itself."
            return
        }
        session.isEnabled = true
        session.connectionPolicy = .anyone
        let address = host.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            status = "Enter the Prism Mac's IP address."
            return
        }
        let networkHost = MIDINetworkHost(name: "Prism", address: address, port: port)
        let connection = MIDINetworkConnection(host: networkHost)
        if session.addConnection(connection) {
            self.connection = connection
            status = "Connected to \(address):\(port)."
        } else {
            status = "Couldn't reach \(address):\(port)."
        }
    }

    /// Connects only when there's no connection yet. Opening the settings
    /// mid-service shouldn't tear down a working network MIDI session and
    /// lose the cues sent while it joins again.
    func applyIfDisconnected() {
        guard connection == nil else { return }
        apply()
    }

    func send(kind: MIDIMessageKind, channel: Int, number: Int, value: Int) {
        let network: MIDIEndpointRef? = location == .network && connection != nil
            ? MIDINetworkSession.default().destinationEndpoint() : nil
        MIDIOutService.shared.sendToPrism(
            kind: kind, channel: channel, number: number, value: value, network: network)
    }

    /// A position's note, on this link's channel.
    func sendCue(note: Int) {
        send(kind: .noteOn, channel: channel, number: note, value: 127)
    }

    /// A slide's (or macro's) Prism scene: the scene's note in Prism now,
    /// so a note changed there still reaches the same scene.
    func fire(_ action: SlideAction) {
        guard let note = PrismScenes.note(for: action, scenes: prismScenes) else {
            DiagnosticsStore.shared.note("prism.noNote", detail: action.prismCueName ?? "")
            return
        }
        DiagnosticsStore.shared.note("prism.scene", detail: "\(action.prismCueName ?? "") note \(note)")
        send(kind: action.midiKind ?? .noteOn, channel: action.midiChannel ?? channel,
             number: note, value: action.midiValue ?? 127)
    }

    // MARK: Prism's scenes

    /// What a slide's right-click › Prism offers: Prism's own scenes when it
    /// runs on this Mac, else the church's cue table, whose positions are
    /// the scenes Prism starts with.
    func sceneChoices(_ model: AppModel) -> [PrismScene] {
        prismScenes.isEmpty
            ? PrismScenes.scenes(fromCueTable: ServiceLighting.table(model))
            : prismScenes
    }

    private var showURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PrismScenes.showURL(applicationSupport: support)
    }

    /// Reads Prism's show and watches its folder: Prism saves by replacing
    /// the file, so the folder is what changes when a scene is added or
    /// renamed.
    func loadScenes() {
        if let data = try? Data(contentsOf: showURL), let scenes = PrismScenes.scenes(fromShow: data) {
            if scenes != prismScenes { prismScenes = scenes }
        }
        guard watcher == nil else { return }
        let folder = showURL.deletingLastPathComponent()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.loadScenes() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}

/// The app's side of ServicePosition: what the library knows about each
/// plan item, and the church's cue table.
@MainActor
enum ServiceLighting {
    static func table(_ model: AppModel) -> [LightingCue] {
        LightingCueTable.effective(model.slideBuilding.lightingCues)
    }

    /// Each plan item's position, by item id.
    static func positions(in service: Service, model: AppModel) -> [String: ServicePosition] {
        let preServiceID = model.slideBuilding.serviceDay?.preServicePresentationId
        return ServicePosition.positions(
            in: service.items, messagePresentationId: service.messagePresentationId,
            customNames: LightingCueTable.customNames(in: table(model))
        ) { item in
            guard item.itemKind == .presentation, let presentation = model.presentation(item.refId) else {
                return ServicePosition.ItemFacts()
            }
            return ServicePosition.ItemFacts(
                category: PresentationTypes.category(of: presentation),
                isPreService: isPreService(presentation, preServiceID: preServiceID))
        }
    }

    static func isPreService(_ presentation: Presentation, preServiceID: String?) -> Bool {
        ServicePosition.isPreServiceSlideshow(
            id: presentation.id, name: presentation.name,
            loops: presentation.autoAdvance?.loopToStart == true,
            preServicePresentationId: preServiceID)
    }

    /// The positions a plan item can be pointed at by hand, in table order.
    static func choices(_ model: AppModel) -> [ServicePosition] {
        let table = table(model)
        return ServicePosition.standard(songs: LightingCueTable.songCount(in: table))
            + LightingCueTable.customNames(in: table).map(ServicePosition.custom)
    }
}

struct PrismSettingsForm: View {
    var model: AppModel?
    @Bindable private var link = PrismLink.shared

    var body: some View {
        Section {
            Picker("Prism runs on", selection: $link.location) {
                ForEach(PrismLink.Location.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .settingsAnchor("midi.prism")
            if link.location == .network {
                LabeledContent("Address") {
                    HStack(spacing: 8) {
                        TextField("", text: $link.host, prompt: Text("192.168.1.40"))
                            .labelsHidden()
                            .frame(width: 140)
                        TextField("", value: $link.port, format: .number.grouping(.never), prompt: Text("Port"))
                            .labelsHidden()
                            .frame(width: 64)
                        Button("Connect") { link.apply() }
                    }
                }
            }
            LabeledContent("Status") {
                Text(link.status).foregroundStyle(.secondary)
            }
            LabeledContent("MIDI channel") {
                Stepper("\(link.channel)", value: $link.channel, in: 1...16)
                    .monospacedDigit()
            }
            LabeledContent("Scenes") {
                Text(link.prismScenes.isEmpty
                     ? "Prism isn't on this Mac: slides offer the lighting cues below."
                     : "\(link.prismScenes.count) from Prism on this Mac")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Prism")
        } footer: {
            Text("To cue a scene from a slide: right-click it › Prism. Prism needs Follow Screens on, and the same MIDI channel as here (Prism › Settings › Screens).")
        }
        .onAppear {
            link.applyIfDisconnected()
            link.loadScenes()
        }
        if let model {
            Section {
                LightingCueTableForm(model: model)
                    .padding(.vertical, 4)
            } header: {
                SettingsHeader(id: "midi.lightingCues")
            }
        }
    }
}

/// Settings › Integrations › Prism & MIDI › Lighting cues: a note per service position.
/// The table is the church's (synced); the switch is this Mac's.
struct LightingCueTableForm: View {
    let model: AppModel
    @Bindable private var link = PrismLink.shared
    @State private var addingCue = false
    @State private var newCueName = ""
    /// Notes typed that weren't saved, by position key, with the reason.
    /// The field shows red until a usable note goes in.
    @State private var refused: [String: (note: Int, reason: String)] = [:]

    var body: some View {
        let table = ServiceLighting.table(model)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $link.followsService) {
                Text("Change Prism scenes with the service").fontWeight(.semibold)
            }
            if !link.followsService {
                Text("Off on this Mac. Prism's scenes start on these notes; turn this on to have them follow the plan.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("When a plan item goes live, Prism gets its position's note. Songs count Song 1, Song 2… down the plan. A header named Message, Baptism, Communion and so on gives its items that position; clicking the header while presenting sends it. Right-click a plan item to pick its cue or turn it off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Position")
                    Text("Note")
                    Text("On")
                    Color.clear.frame(width: 1, height: 1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(table, id: \.position) { row in
                    cueRow(row, in: table)
                }
            }
            HStack {
                Button("Add Song") { addSong(to: table) }
                Button("Add Cue…") { addingCue = true }
                Button("Use Defaults") { save(LightingCueTable.defaults) }
                    .disabled(table == LightingCueTable.defaults)
            }
            ForEach(table.filter { refused[$0.position] != nil }, id: \.position) { row in
                if let refusal = refused[row.position] {
                    Text("\(ServicePosition(key: row.position)?.title ?? row.position): \(refusal.note) not saved. \(refusal.reason)")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Text("Songs past the last song row use it. Notes go out on channel \(link.channel). To give a Prism scene one of these notes, press Learn on it in Prism, then Send here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Add Cue", isPresented: $addingCue) {
            TextField("Name, e.g. Prayer", text: $newCueName)
            Button("Add") { addCustom(named: newCueName, to: table) }
            Button("Cancel", role: .cancel) { newCueName = "" }
        } message: {
            Text("A header with this name gives its items this cue.")
        }
    }

    @ViewBuilder
    private func cueRow(_ row: LightingCue, in table: [LightingCue]) -> some View {
        let position = ServicePosition(key: row.position)
        GridRow {
            Text(position?.title ?? row.position)
            // A note that's reserved or another row's would fire two scenes
            // at once (Song 1 on 4 goes up on every Chorus), so it isn't
            // saved: the field goes red with the reason under the table.
            TextField("Note", value: Binding(
                get: { refused[row.position]?.note ?? row.note },
                set: { note in
                    if let reason = LightingCueTable.noteProblem(note, for: row.position, in: table) {
                        refused[row.position] = (note, reason)
                    } else {
                        update(row.position, in: table) { $0.note = note }
                    }
                }
            ), format: .number.grouping(.never))
            // A grouped Form shows a text field's title above it, which put
            // "Note" over every row under the column's own heading.
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .overlay {
                if refused[row.position] != nil {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.red, lineWidth: 1.5)
                }
            }
            .frame(width: 52)
            Toggle("On", isOn: Binding(
                get: { row.off != true },
                set: { on in update(row.position, in: table) { $0.off = on ? nil : true } }
            ))
            .labelsHidden()
            HStack(spacing: 6) {
                Button("Send") { link.sendCue(note: row.note) }
                    .controlSize(.small)
                if isRemovable(position) {
                    Button {
                        save(table.filter { $0.position != row.position })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }
    }

    /// The standard rows stay (turn one off instead); added songs and
    /// custom cues can go.
    private func isRemovable(_ position: ServicePosition?) -> Bool {
        switch position {
        case .song(let number): number > 5
        case .custom: true
        default: false
        }
    }

    private func update(_ key: String, in table: [LightingCue], _ change: (inout LightingCue) -> Void) {
        var table = table
        guard let index = table.firstIndex(where: { $0.position == key }) else { return }
        change(&table[index])
        save(table)
    }

    private func addSong(to table: [LightingCue]) {
        let number = LightingCueTable.songCount(in: table) + 1
        let row = LightingCue(position: ServicePosition.song(number).key, note: LightingCueTable.nextFreeNote(in: table))
        var table = table
        let lastSong = table.lastIndex { if case .song? = ServicePosition(key: $0.position) { true } else { false } }
        table.insert(row, at: lastSong.map { $0 + 1 } ?? table.endIndex)
        save(table)
    }

    private func addCustom(named name: String, to table: [LightingCue]) {
        newCueName = ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let position = ServicePosition.custom(trimmed)
        guard !table.contains(where: { $0.position == position.key }) else { return }
        save(table + [LightingCue(position: position.key, note: LightingCueTable.nextFreeNote(in: table))])
    }

    private func save(_ table: [LightingCue]) {
        // Any change to the table (Use Defaults, a row removed, another
        // note saved) shows the saved notes again.
        refused = [:]
        model.updateSlideBuilding { $0.lightingCues = table }
    }
}
