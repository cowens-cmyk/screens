import Foundation
import Observation
import OutputEngine
import SwiftUI

/// Finds Blackmagic DeckLink outputs on its own: at launch and every few
/// seconds after, so a card or UltraStudio plugged in mid-week appears as a
/// choice in the Audience, Livestream and Stage cards. Ports mapped as
/// inputs in Desktop Video Setup are left for capture.
@MainActor
@Observable
final class DeckLinkAutoSetup {
    static let shared = DeckLinkAutoSetup()

    private var watching: Task<Void, Never>?

    private init() {}

    var summary: String {
        let catalog = DeckLinkDeviceCatalog.shared
        if catalog.runtimeTooOld { return "Desktop Video \(catalog.runtimeVersionLabel) is too old — install 16.0 or later." }
        if catalog.hasFetched, catalog.runtimeVersionLabel.isEmpty, catalog.devices.isEmpty {
            return "Blackmagic Desktop Video isn't installed (or its driver isn't allowed in System Settings › Privacy & Security)."
        }
        guard catalog.hasFetched else { return "Looking for DeckLink devices…" }
        let outputs = catalog.devices.filter { catalog.displayModes[$0.persistentID]?.isEmpty == false }
        let names = outputs.map(\.name).joined(separator: ", ")
        return outputs.isEmpty
            ? "No DeckLink output ports found (Desktop Video \(catalog.runtimeVersionLabel))."
            : "Outputs: \(names)"
    }

    /// What the driver actually reported, in one copyable block.
    static var details: String {
        let catalog = DeckLinkDeviceCatalog.shared
        var lines = ["Desktop Video: \(catalog.runtimeVersionLabel.isEmpty ? "not found" : catalog.runtimeVersionLabel)\(catalog.runtimeTooOld ? " (needs 16.0+)" : "")"]
        if catalog.allDevices.isEmpty {
            lines.append(catalog.hasFetched ? "Ports: none reported" : "Ports: checking…")
        }
        for device in catalog.allDevices {
            let modes = catalog.displayModes[device.persistentID]
            let role = !device.supportsPlayback ? "capture only"
                : modes == nil ? "output (checking modes)"
                : modes!.isEmpty ? "mapped as input" : "output, \(modes!.count) modes"
            lines.append("• \(device.name) — \(role)")
        }
        return lines.joined(separator: "\n")
    }

    func start() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                DeckLinkDeviceCatalog.shared.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func refreshNow() {
        DeckLinkDeviceCatalog.shared.refresh()
    }
}

struct DeckLinkSetupForm: View {
    @Bindable private var setup = DeckLinkAutoSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(setup.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Find Devices") { setup.refreshNow() }
            }
            Text(DeckLinkAutoSetup.details)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Pick a DeckLink port as a screen's output in the cards above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
