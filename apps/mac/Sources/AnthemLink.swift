import Foundation
import Network
import Observation
import PresenterCore
import SlideScene

/// Lets Anthem (the multitrack app on the band's Mac) drive the slides.
/// Anthem already speaks ProPresenter's network API to change slides on the
/// cue, timed to the tracks, so Screens answers the same requests on the same
/// port: point Anthem's ProPresenter address at this Mac and the section the
/// tracks are playing is the slide on screen, in whatever order the band
/// plays the song.
///
/// Requests answered (ProPresenter API v1, what Anthem uses):
///   GET /version
///   GET /v1/libraries, /v1/library/{name}      the songs and presentations
///   GET /v1/playlists, /v1/playlist/active, /v1/playlist/{id}   the plans
///   GET /v1/presentation/active, /v1/presentation/{uuid}   slides by section
///   GET /v1/presentation/{uuid|active}/{index}/trigger      show that slide
@MainActor
@Observable
final class AnthemLink {
    static let shared = AnthemLink()
    static let port: UInt16 = 50001

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "anthem.enabled")
            enabled ? start() : stop()
        }
    }
    private(set) var listening = false
    private(set) var lastCue: String?
    private(set) var lastCueAt: Date?
    private(set) var error: String?

    private weak var model: AppModel?
    private weak var controls: ServiceControls?
    @ObservationIgnored private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.hopejc.screens.anthem")

    private init() {
        enabled = UserDefaults.standard.object(forKey: "anthem.enabled") as? Bool ?? true
    }

    func attach(model: AppModel, controls: ServiceControls) {
        self.model = model
        self.controls = controls
        if enabled { start() }
    }

    /// This Mac's addresses, for Anthem's Settings › ProPresenter.
    var addresses: [String] {
        var result: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    private func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.listening = true; self?.error = nil
                    case .failed(let error):
                        self?.listening = false
                        self?.error = "Couldn't listen on port \(Self.port): \(error.localizedDescription). Is ProPresenter running on this Mac?"
                    case .cancelled: self?.listening = false
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        listening = false
    }

    // MARK: HTTP

    nonisolated private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]) : "/"
            Task { @MainActor in
                let (status, body) = method == "GET" ? self.answer(path) : (405, Data())
                connection.send(content: Self.response(status: status, body: body), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    nonisolated private static func response(status: Int, body: Data) -> Data {
        let reason = [200: "OK", 204: "No Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    // MARK: Answers

    private func answer(_ rawPath: String) -> (Int, Data) {
        guard let model else { return (404, Data()) }
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        func json(_ object: Any) -> (Int, Data) {
            (200, (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data())
        }
        let p = parts + ["", "", "", "", ""]
        let count = parts.count
        if parts == ["version"] {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            return json([
                "name": Host.current().localizedName ?? "Screens", "platform": "mac",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "host_description": "Screens \(version)", "api_version": "v1",
            ])
        } else if parts == ["v1", "libraries"] {
            return json(ProPresenterCompat.libraries(libraryItems(model)))
        } else if count == 3, p[0] == "v1", p[1] == "library" {
            let items = ProPresenterCompat.libraryItems(libraryItems(model), named: p[2])
            // Anthem reads `updateType`; ProPresenter itself says
            // `update_type`. Both, so either reader is happy.
            return json(["updateType": "all", "update_type": "all", "items": items])
        } else if parts == ["v1", "playlists"] {
            let plans = model.resident.services.values.filter { $0.isTemplate != true }
                .sorted { $0.serviceDate > $1.serviceDate }
            return json(plans.enumerated().map { index, plan in
                ["id": ["uuid": plan.id, "name": plan.name, "index": index], "type": "playlist"] as [String: Any]
            })
        } else if parts == ["v1", "playlist", "active"] {
            guard let plan = model.currentServiceID.flatMap({ model.resident.services.value($0) }) else {
                return json(["presentation": NSNull()])
            }
            return json(["presentation": ["playlist": ["uuid": plan.id, "name": plan.name, "index": 0]]])
        } else if count == 3, p[0] == "v1", p[1] == "playlist" {
            let id = p[2]
            guard let plan = model.resident.services.value(id) else { return (404, Data()) }
            let items = plan.items.enumerated().map { index, item in
                ProPresenterCompat.playlistItem(
                    item, index: index,
                    presentation: item.itemKind == .presentation ? model.presentation(item.refId) : nil)
            }
            return json(["id": ["uuid": plan.id, "name": plan.name, "index": 0], "items": items])
        } else if parts == ["v1", "presentation", "active"] {
            guard let id = controls?.livePresentationID, let presentation = model.presentation(id) else {
                return json(["presentation": NSNull()])
            }
            return json(["presentation": ProPresenterCompat.describe(presentation)])
        } else if count == 3, p[0] == "v1", p[1] == "presentation" {
            let id = p[2]
            guard let presentation = model.presentation(id) else { return (404, Data()) }
            return json(["presentation": ProPresenterCompat.describe(presentation)])
        } else if count == 5, p[0] == "v1", p[1] == "presentation", p[4] == "trigger" {
            let id = p[2]
            guard let slideIndex = Int(p[3]) else { return (404, Data()) }
            guard let presentationID = id == "active" ? controls?.livePresentationID : id else { return (404, Data()) }
            return cue(presentationID: presentationID, index: slideIndex, itemID: nil)
                ? (204, Data()) : (404, Data())
        }
        return (404, Data())
    }

    private func libraryItems(_ model: AppModel) -> [ProPresenterCompat.LibraryItem] {
        model.entries(of: .presentation).map { .init(id: $0.id, name: $0.name, folder: $0.subkind) }
    }

    /// The current plan's items in the order /v1/playlist lists them, so
    /// Anthem's Select Playlist Item over MIDI picks the item it would over
    /// the network.
    func playlistItems() -> [ServiceItem]? {
        model?.currentServiceID.flatMap { model?.resident.services.value($0) }?.items
    }

    /// Shows slide `index` of the presentation's own slide order — the
    /// order /v1/presentation describes — for a network trigger or Anthem's
    /// MIDI Trigger Slide alike. In the current plan it shows as that plan
    /// item, at the arrangement's next place for that slide, so the grid
    /// lights the tile the band is on.
    @discardableResult
    func cue(presentationID: String, index: Int, itemID: String?) -> Bool {
        guard let model, let controls,
              let presentation = model.presentation(presentationID),
              presentation.slides.indices.contains(index) else { return false }
        let slide = presentation.slides[index]
        let items = playlistItems() ?? []
        // A network trigger names only the presentation; a song sung twice
        // lands on the live one, the next one, or the one Anthem says it's
        // playing (AnthemCue.planItem), not always the first.
        func find(_ id: String?) -> ServiceItem? { id.flatMap { id in items.first { $0.id == id } } }
        let item = find(itemID) ?? find(AnthemCue.planItem(
            for: presentationID, in: items.filter { !$0.isHidden }.map { ($0.id, $0.refId) },
            liveItemID: controls.liveContextID,
            anthemItemID: model.currentServiceID.flatMap { AnthemFeed.shared.liveItemID(serviceID: $0, model: model) }))
        let arranged = model.arrangedSlides(presentation, arrangementId: item?.arrangementId).map(\.id)
        let current = controls.liveContextID == item?.id ? controls.liveOccurrence : nil
        controls.fire(
            slide: slide, in: presentation, arrangementId: item?.arrangementId, contextID: item?.id,
            occurrence: item == nil ? nil : AnthemCue.occurrence(of: slide.id, in: arranged, current: current))
        let section = (presentation.sections ?? []).first { $0.id == slide.sectionId }?.name
        lastCue = [presentation.name, section].compactMap { $0 }.joined(separator: " · ")
        lastCueAt = .now
        return true
    }
}

import SwiftUI

/// Settings › Integrations › Anthem: what to type into Anthem, and whether
/// cues arrive; then the setlist and the MIDI fallback. Form sections.
struct AnthemSettingsForm: View {
    @Bindable private var link = AnthemLink.shared

    var body: some View {
        Section {
            Toggle("Let Anthem change the slides", isOn: $link.enabled)
                .toggleStyle(.switch)
                .settingsAnchor("anthem.link")
            if link.enabled {
                LabeledContent("Status") {
                    StatusDot(
                        color: link.listening ? .green : .orange,
                        text: link.listening ? "Listening on port \(AnthemLink.port)" : "Not listening")
                }
                LabeledContent("Enter in Anthem") {
                    Text(verbatim: "\(link.addresses.first ?? "this Mac's address") port \(AnthemLink.port)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                if link.addresses.count > 1 {
                    LabeledContent("Other addresses") {
                        Text(link.addresses.dropFirst().joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                }
                if let cue = link.lastCue, let at = link.lastCueAt {
                    LabeledContent("Last cue") {
                        Text("\(cue) at \(at.formatted(date: .omitted, time: .standard))")
                    }
                }
                if let error = link.error {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Anthem")
        } footer: {
            Text(link.enabled
                ? "In Anthem › Settings › ProPresenter, choose Network and enter the address above. Then link each song to its presentation; the tracks change the slides on their cues."
                : SettingsIndex.entry("anthem.link")?.caption ?? "")
        }
        AnthemFeedSettings()
        AnthemMIDISettings()
    }
}

/// A coloured dot and a short status, for connection rows.
struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// Settings › Integrations › Anthem: reading Anthem's setlist and song orders.
private struct AnthemFeedSettings: View {
    @Bindable private var feed = AnthemFeed.shared
    @State private var address = AnthemFeed.shared.manualAddress

    var body: some View {
        Section {
            Toggle("Match song orders to Anthem's setlist", isOn: $feed.enabled)
                .toggleStyle(.switch)
            if feed.enabled {
                LabeledContent("Status") {
                    StatusDot(color: dotColor, text: statusText)
                }
                LabeledContent {
                    TextField("", text: $address, prompt: Text("Found automatically"))
                        .labelsHidden()
                        .frame(width: 220)
                        .onSubmit { feed.manualAddress = address }
                } label: {
                    Text("Anthem address")
                    Text("Empty finds Anthem on the network. Otherwise its Mac's address, port \(String(AnthemShow.defaultPort)) unless you add one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Toggle("Ignore instrumental sections", isOn: $feed.ignoreInstrumental)
                    .toggleStyle(.switch)
                    .help("Intros, turnarounds and other band-only parts with no blank slide in Screens don't count as a difference.")
                Toggle("Match Anthem automatically", isOn: $feed.autoMatch)
                    .toggleStyle(.switch)
            }
        } header: {
            Text("Setlist")
        } footer: {
            if feed.enabled {
                Text("Upcoming plans Anthem's setlist is for. A song that differs gets an arrangement in Anthem's order (Anthem, or Anthem – and the plan's date when another plan uses that one). A song on screen is left alone.")
            }
        }
        .onDisappear {
            if address != feed.manualAddress { feed.manualAddress = address }
        }
    }

    private var dotColor: Color {
        switch feed.connection {
        case .connected: .green
        case .searching: .secondary
        case .notFound, .off: .orange
        }
    }

    private var statusText: String {
        switch feed.connection {
        case .off: "Off"
        case .searching: "Looking for Anthem…"
        case .notFound: "Anthem not found"
        case .connected(let name):
            if let setlist = feed.setlist {
                "\(name) · \(setlist.name), \(setlist.entries.count) songs"
            } else {
                "\(name) · no setlist open"
            }
        }
    }
}

/// Settings › Integrations › Anthem: Anthem's MIDI fallback.
private struct AnthemMIDISettings: View {
    @Bindable private var feed = AnthemFeed.shared

    var body: some View {
        Section {
            Toggle("Listen to Anthem's MIDI", isOn: $feed.followMIDI)
                .toggleStyle(.switch)
                .settingsAnchor("anthem.midi")
            if feed.followMIDI {
                LabeledContent("Status") {
                    StatusDot(
                        color: feed.midiConnected ? .green : .secondary,
                        text: feed.midiConnected ? "Connected to Anthem's MIDI source" : "Anthem's MIDI source isn't open")
                }
                Picker("Notes", selection: $feed.midiUsesAnthemNotes) {
                    Text("Anthem's").tag(true)
                    Text("MIDI input map").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        } header: {
            Text("MIDI")
        } footer: {
            if feed.followMIDI {
                Text("Anthem's notes, channel 1: Next 13, Previous 14, Select Item 19, Trigger Slide 20 (velocity is the slide number). The choice covers Anthem's own MIDI source and the Screens In destination, so Anthem can send to either; a message that arrives on both counts once. If another app sends to Screens In, choose MIDI input map. MIDI devices added in Settings › Integrations › Lightkey & MIDI always use the map.")
            }
        }
    }
}
