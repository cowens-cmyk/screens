import Foundation
import Observation

/// DeckLink ports that can capture, as the DeckLink helper sees them. Sub-devices whose
/// connector is mapped as an output in Desktop Video Setup come back with
/// `usableForCapture == false`, so the UI can show why they can't be picked.
@MainActor
@Observable
final class DeckLinkInputCatalog {
    static let shared = DeckLinkInputCatalog()

    private(set) var ports: [DeckLinkHelperInputDevice] = []
    private(set) var hasFetched = false

    /// nil until the first answer; false when Desktop Video isn't installed.
    private(set) var runtimeAvailable: Bool?
    private(set) var runtimeTooOld = false

    private var inFlight = false

    private init() {}

    var capturePorts: [DeckLinkHelperInputDevice] {
        ports.filter(\.usableForCapture)
    }

    func port(id: String?) -> DeckLinkHelperInputDevice? {
        guard let id, let persistentID = Int64(id) else { return nil }
        return ports.first { $0.persistentID == persistentID }
    }

    /// Why the menu has nothing to offer, or nil when it does.
    var emptyReason: String? {
        if !capturePorts.isEmpty { return nil }
        if runtimeAvailable == false { return "DeckLink unavailable \u{2014} Desktop Video not installed" }
        if runtimeTooOld { return "Desktop Video is too old \u{2014} update it" }
        if !hasFetched { return "Looking for DeckLink cards\u{2026}" }
        if !ports.isEmpty { return "No DeckLink port is mapped as an input (Desktop Video Setup)" }
        return "No DeckLink capture ports found"
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.resume()
        nonisolated(unsafe) let replyConnection = connection
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            replyConnection.invalidate()
            Task { @MainActor in DeckLinkInputCatalog.shared.inFlight = false }
        }) as? DeckLinkHelperProtocol else {
            connection.invalidate()
            inFlight = false
            return
        }
        proxy.runtimeVersion { @Sendable version, tooOld in
            Task { @MainActor in
                let catalog = DeckLinkInputCatalog.shared
                catalog.runtimeAvailable = !version.isEmpty
                catalog.runtimeTooOld = tooOld
            }
        }
        proxy.listInputDevices { @Sendable data in
            let ports = (try? JSONDecoder().decode(
                [DeckLinkHelperInputDevice].self, from: data)) ?? []
            Task { @MainActor in
                let catalog = DeckLinkInputCatalog.shared
                catalog.ports = ports
                catalog.hasFetched = true
                catalog.inFlight = false
                replyConnection.invalidate()
            }
        }
    }
}
