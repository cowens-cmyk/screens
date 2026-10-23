import CoreMIDI
import Foundation
import Observation
import PresenterCore
import SwiftUI

/// Lightkey listens to MIDI. On this Mac it picks the "Screens" MIDI port;
/// on another Mac, Screens joins it over network MIDI (the same session
/// Audio MIDI Setup › Network shows), so cues travel over the LAN.
@MainActor
@Observable
final class LightkeyLink {
    static let shared = LightkeyLink()
    /// A MIDI Out action aimed at Lightkey carries this as its device.
    static let deviceID = "lightkey"

    enum Location: String, CaseIterable, Identifiable {
        case thisMac, network
        var id: String { rawValue }
        var title: String { self == .thisMac ? "This Mac" : "Another Mac on the network" }
    }

    var location: Location { didSet { save(); apply() } }
    var host: String { didSet { save() } }
    var port: Int { didSet { save() } }
    /// Lightkey learns whatever channel it hears; one channel keeps
    /// Screens' cues apart from other controllers.
    var channel: Int { didSet { save() } }
    /// Sends a note when the song moves to a new section (Verse, Chorus…).
    var sendsSections: Bool { didSet { save() } }

    /// Changes Lightkey's scene as the service moves: each plan item sends
    /// its position's note (Walk-in, Song 1, Message…) when it goes live.
    /// Per Mac, like the rest of this link; the note table is the church's.
    var followsService: Bool {
        get { followChoice ?? configured }
        set { followChoice = newValue; save() }
    }
    /// Unset until someone flips the switch: until then it follows whether
    /// Lightkey has been set up on this Mac at all.
    private var followChoice: Bool?
    /// Any Lightkey setting saved, or a cue or test note sent from here.
    private var configured: Bool

    private(set) var status = ""

    private var connection: MIDINetworkConnection?
    private var lastSection: String?

    private init() {
        let defaults = UserDefaults.standard
        location = defaults.string(forKey: "lightkey.location").flatMap(Location.init(rawValue:)) ?? .thisMac
        host = defaults.string(forKey: "lightkey.host") ?? ""
        port = defaults.object(forKey: "lightkey.port") as? Int ?? 5004
        channel = defaults.object(forKey: "lightkey.channel") as? Int ?? 16
        sendsSections = defaults.bool(forKey: "lightkey.sections")
        followChoice = defaults.object(forKey: "lightkey.followService") as? Bool
        configured = defaults.bool(forKey: "lightkey.configured")
            || defaults.object(forKey: "lightkey.location") != nil
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(location.rawValue, forKey: "lightkey.location")
        defaults.set(host, forKey: "lightkey.host")
        defaults.set(port, forKey: "lightkey.port")
        defaults.set(channel, forKey: "lightkey.channel")
        defaults.set(sendsSections, forKey: "lightkey.sections")
        defaults.set(followChoice, forKey: "lightkey.followService")
        markConfigured()
    }

    private func markConfigured() {
        guard !configured else { return }
        configured = true
        UserDefaults.standard.set(true, forKey: "lightkey.configured")
    }

    func start() {
        MIDIOutService.shared.prepare()
        apply()
    }

    /// Joins (or leaves) the network MIDI session and connects to the
    /// Lightkey Mac's session.
    func apply() {
        let session = MIDINetworkSession.default()
        if let connection {
            session.removeConnection(connection)
            self.connection = nil
        }
        guard location == .network else {
            status = "In Lightkey, choose the MIDI input named “Screens”."
            return
        }
        session.isEnabled = true
        session.connectionPolicy = .anyone
        let address = host.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            status = "Enter the Lightkey Mac's IP address."
            return
        }
        let networkHost = MIDINetworkHost(name: "Lightkey", address: address, port: port)
        let connection = MIDINetworkConnection(host: networkHost)
        if session.addConnection(connection) {
            self.connection = connection
            status = "Connected to \(address):\(port). In Lightkey, choose that Mac's network session as a MIDI input."
        } else {
            status = "Couldn't reach \(address):\(port)."
        }
    }

    func send(kind: MIDIMessageKind, channel: Int, number: Int, value: Int) {
        markConfigured()
        let network: MIDIEndpointRef? = location == .network && connection != nil
            ? MIDINetworkSession.default().destinationEndpoint() : nil
        MIDIOutService.shared.sendToLightkey(
            kind: kind, channel: channel, number: number, value: value, network: network)
    }

    /// A note Lightkey can MIDI-learn: press Test while Lightkey is learning.
    func sendTest(note: Int = 0) {
        send(kind: .noteOn, channel: channel, number: note, value: 127)
    }

    /// A position's note, on this link's channel.
    func sendCue(note: Int) {
        send(kind: .noteOn, channel: channel, number: note, value: 127)
    }

    // MARK: Song sections

    /// Section notes: Lightkey learns each once, then follows every song.
    static let sectionNotes: [(name: String, note: Int)] = [
        ("Intro", 1), ("Verse", 2), ("Pre-Chorus", 3), ("Chorus", 4), ("Bridge", 5),
        ("Tag", 6), ("Interlude", 7), ("Instrumental", 8), ("Outro", 9), ("Ending", 10),
    ]

    static func note(forSection name: String) -> Int? {
        let lowered = name.lowercased()
        return sectionNotes
            .sorted { $0.name.count > $1.name.count }
            .first { lowered.hasPrefix($0.name.lowercased()) }?.note
    }

    func slideWentLive(_ slide: Slide, in presentation: Presentation) {
        guard sendsSections else { return }
        let section = slide.sectionId.flatMap { id in presentation.sections?.first { $0.id == id }?.name }
        let key = "\(presentation.id)|\(section ?? "")"
        guard key != lastSection else { return }
        lastSection = key
        if let section, let note = Self.note(forSection: section) {
            send(kind: .noteOn, channel: channel, number: note, value: 127)
        }
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

struct LightkeySettingsForm: View {
    var model: AppModel?
    @Bindable private var link = LightkeyLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Lightkey runs on", selection: $link.location) {
                ForEach(LightkeyLink.Location.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if link.location == .network {
                HStack {
                    TextField("IP address, e.g. 192.168.1.40", text: $link.host)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", value: $link.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Button("Connect") { link.apply() }
                }
                Text("On the Lightkey Mac: Audio MIDI Setup › Window › Show MIDI Studio › Network — create a session, turn it on and allow anyone to connect (port 5004).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(link.status).font(.caption).foregroundStyle(.secondary)
            Stepper("MIDI channel: \(link.channel)", value: $link.channel, in: 1...16)
            HStack {
                Button("Send Test Note") { link.sendTest() }
                Text("Put a Lightkey cue in MIDI learn, then press this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Send song sections (Verse, Chorus, Bridge…)", isOn: $link.sendsSections)
            if link.sendsSections {
                Text(LightkeyLink.sectionNotes.map { "\($0.name) = note \($0.note)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("To fire a Lightkey cue from a slide: right-click › Add Action › Lightkey Cue.")
                .font(.caption).foregroundStyle(.secondary)
            if let model {
                Divider()
                LightingCueTableForm(model: model)
            }
        }
        .onAppear { link.apply() }
    }
}

/// Settings › MIDI › Lightkey › Lighting cues: a note per service position.
/// The table is the church's (synced); the switch is this Mac's.
struct LightingCueTableForm: View {
    let model: AppModel
    @Bindable private var link = LightkeyLink.shared
    @State private var addingCue = false
    @State private var newCueName = ""

    var body: some View {
        let table = ServiceLighting.table(model)
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Change Lightkey scenes with the service", isOn: $link.followsService)
            Text("When a plan item goes live, Lightkey gets its position's note. Songs count Song 1, Song 2… down the plan. A header named Message, Baptism, Communion and so on gives its items that position. Right-click a plan item to pick its cue or turn it off.")
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
            Text("Songs past the last song row use it. Press Send while a Lightkey cue is in MIDI learn. Notes go out on channel \(link.channel).")
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
            TextField("Note", value: Binding(
                get: { row.note },
                set: { note in update(row.position, in: table) { $0.note = min(max(note, 0), 127) } }
            ), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
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
        model.updateSlideBuilding { $0.lightingCues = table }
    }
}
