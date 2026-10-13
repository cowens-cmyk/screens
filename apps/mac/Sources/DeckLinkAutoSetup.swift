import Foundation
import Observation
import OutputEngine
import SwiftUI

/// Finds Blackmagic DeckLink outputs on its own: at launch and every few
/// seconds after (so a card or UltraStudio plugged in mid-week appears), and
/// gives each output port it hasn't seen before a screen of its own, already
/// sending. Ports mapped as inputs in Desktop Video Setup are left for
/// capture. A screen the operator deletes isn't recreated.
@MainActor
@Observable
final class DeckLinkAutoSetup {
    static let shared = DeckLinkAutoSetup()

    private static let enabledKey = "decklink.autoScreens"
    private static let knownKey = "decklink.knownOutputs"

    var addsScreens: Bool {
        didSet { UserDefaults.standard.set(addsScreens, forKey: Self.enabledKey) }
    }
    private(set) var lastAdded: [String] = []
    private var known: Set<Int64>
    private var watching: Task<Void, Never>?

    private init() {
        addsScreens = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        known = Set((UserDefaults.standard.array(forKey: Self.knownKey) as? [NSNumber] ?? []).map(\.int64Value))
    }

    var summary: String {
        let catalog = DeckLinkDeviceCatalog.shared
        if catalog.runtimeTooOld { return "Desktop Video \(catalog.runtimeVersionLabel) is too old — install 16.0 or later." }
        if catalog.hasFetched, catalog.runtimeVersionLabel.isEmpty, catalog.devices.isEmpty {
            return "No DeckLink devices found. Is Blackmagic Desktop Video installed?"
        }
        guard catalog.hasFetched else { return "Looking for DeckLink devices…" }
        let outputs = catalog.devices.filter { catalog.displayModes[$0.persistentID]?.isEmpty == false }
        let names = outputs.map(\.name).joined(separator: ", ")
        return outputs.isEmpty
            ? "No DeckLink output ports found (Desktop Video \(catalog.runtimeVersionLabel))."
            : "Outputs: \(names)"
    }

    func start(render: RenderContext) {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                DeckLinkDeviceCatalog.shared.refresh()
                // Display modes arrive just after the device list.
                try? await Task.sleep(for: .seconds(2))
                self?.adopt(render: render)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func refreshNow(render: RenderContext) {
        DeckLinkDeviceCatalog.shared.refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.adopt(render: render)
        }
    }

    private func adopt(render: RenderContext) {
        let catalog = DeckLinkDeviceCatalog.shared
        guard addsScreens, catalog.hasFetched else { return }
        let outputs = DeckLinkScreenOutputs.shared
        var added: [String] = []
        for device in catalog.devices where !known.contains(device.persistentID) {
            guard let modes = catalog.displayModes[device.persistentID] else { continue }
            known.insert(device.persistentID)
            // Mapped as an input, or already carrying a screen: nothing to add.
            guard !modes.isEmpty, outputs.members(onDevice: device.persistentID).isEmpty else { continue }
            render.outputs.addPlaceholderScreen(name: device.name, width: 1920, height: 1080)
            guard let screen = render.outputs.placeholderScreens.last else { continue }
            outputs.enable(screenID: screen.id, device: device, keying: .off, render: render)
            added.append(device.name)
            DiagnosticsStore.shared.note("decklink.autoScreen", detail: device.name)
        }
        UserDefaults.standard.set(known.map { NSNumber(value: $0) }, forKey: Self.knownKey)
        if !added.isEmpty { lastAdded = added }
    }
}

struct DeckLinkSetupForm: View {
    let render: RenderContext
    @Bindable private var setup = DeckLinkAutoSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Add a screen for each DeckLink output automatically", isOn: $setup.addsScreens)
            HStack {
                Text(setup.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Find Devices") { setup.refreshNow(render: render) }
            }
            if !setup.lastAdded.isEmpty {
                Text("Added: \(setup.lastAdded.joined(separator: ", ")). Choose what each shows in Show Setup above, and turn on Alpha Key for the livestream in Screen Configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
