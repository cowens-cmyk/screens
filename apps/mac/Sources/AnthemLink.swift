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
            return json([["id": ["uuid": "screens", "name": "Screens", "index": 0]]])
        } else if count == 3, p[0] == "v1", p[1] == "library" {
            let items = model.entries(of: .presentation)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .enumerated().map { ["uuid": $1.id, "name": $1.name, "index": $0] as [String: Any] }
            return json(["update_type": "all", "items": items])
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
            let items = plan.items.enumerated().map { index, item -> [String: Any] in
                var entry: [String: Any] = [
                    "id": ["uuid": item.id, "name": item.name, "index": index],
                    "type": item.itemKind == .presentation ? "presentation" : item.itemKind == .header ? "header" : "media",
                ]
                if item.itemKind == .presentation {
                    entry["presentation_info"] = ["presentation_uuid": item.refId]
                }
                return entry
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
            return trigger(presentationID: id == "active" ? controls?.livePresentationID : id, index: slideIndex)
                ? (204, Data()) : (404, Data())
        }
        return (404, Data())
    }

    /// Shows slide `index`, from the current plan when the presentation is in it.
    private func trigger(presentationID: String?, index: Int) -> Bool {
        guard let model, let controls, let presentationID,
              let presentation = model.presentation(presentationID),
              presentation.slides.indices.contains(index) else { return false }
        let slide = presentation.slides[index]
        let item = model.currentServiceID.flatMap { model.resident.services.value($0) }?
            .items.first { $0.refId == presentationID }
        controls.fire(slide: slide, in: presentation, contextID: item?.id)
        let section = (presentation.sections ?? []).first { $0.id == slide.sectionId }?.name
        lastCue = [presentation.name, section].compactMap { $0 }.joined(separator: " · ")
        lastCueAt = .now
        return true
    }
}

import SwiftUI

/// Settings › Anthem: what to type into Anthem, and whether cues arrive.
struct AnthemSettingsForm: View {
    @Bindable private var link = AnthemLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Let Anthem change the slides", isOn: $link.enabled)
            if link.enabled {
                HStack(spacing: 6) {
                    Circle().fill(link.listening ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(link.listening ? "Listening on port \(AnthemLink.port)" : "Not listening")
                        .font(.caption)
                }
                Text("In Anthem › Settings › ProPresenter, choose Network and enter \(link.addresses.first ?? "this Mac's address") port \(AnthemLink.port). Then link each song to its presentation here; the tracks change the slides on their cues.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if link.addresses.count > 1 {
                    Text("Other addresses: " + link.addresses.dropFirst().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let cue = link.lastCue, let at = link.lastCueAt {
                    Text("Last cue: \(cue) at \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = link.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}
