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
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(location.rawValue, forKey: "lightkey.location")
        defaults.set(host, forKey: "lightkey.host")
        defaults.set(port, forKey: "lightkey.port")
        defaults.set(channel, forKey: "lightkey.channel")
        defaults.set(sendsSections, forKey: "lightkey.sections")
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
        let network: MIDIEndpointRef? = location == .network && connection != nil
            ? MIDINetworkSession.default().destinationEndpoint() : nil
        MIDIOutService.shared.sendToLightkey(
            kind: kind, channel: channel, number: number, value: value, network: network)
    }

    /// A note Lightkey can MIDI-learn: press Test while Lightkey is learning.
    func sendTest(note: Int = 0) {
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

struct LightkeySettingsForm: View {
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
        }
        .onAppear { link.apply() }
    }
}
