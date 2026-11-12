import AppKit
import Foundation
import PresenterCore
import SwiftUI

/// Keeps "Run on this Mac" and the church library's Main Mac in step
/// (MainMac decides how): turning Run on this Mac on makes this Mac the
/// Main Mac for every linked Mac, and the old one steps down by itself.
/// A Mac that isn't linked is left alone: it runs on its own.
@MainActor
@Observable
final class MainMacCoordinator {
    static let shared = MainMacCoordinator()

    private static let idKey = "station.id"
    private static let tickSeconds: TimeInterval = 2
    /// A claim waits this long for the library to show it before claiming again.
    private static let claimPatience: TimeInterval = 15

    /// This Mac's id in the church library: made once, kept per Mac.
    static var thisMacID: String {
        if let id = UserDefaults.standard.string(forKey: idKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    /// The name the other Macs see: its Sync name, else the Mac's own.
    static var thisMacName: String {
        CloudSync.shared.deviceName ?? Host.current().localizedName ?? "This Mac"
    }

    /// For Settings: this Mac's role and the Main Mac's name.
    private(set) var role = MainMac.Role.onItsOwn
    private(set) var mainMacName: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSeen: String??
    @ObservationIgnored private var lastClaim: Date?

    static var isLinked: Bool {
        switch CloudSync.shared.status {
        case .notLinked, .unlinked: false
        default: true
        }
    }

    func start(model: AppModel) {
        self.model = model
        model.whenLibraryReady { [weak self] in
            Task { @MainActor in
                await model.resident.ready([.slideBuildingSettings])
                self?.tick()
                self?.timer?.invalidate()
                self?.timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            }
        }
    }

    /// Settings' Make This the Main Mac.
    func makeThisMacMain() {
        ServiceStation.runsService = true
        tick()
    }

    private func tick() {
        guard let model else { return }
        let settings = model.slideBuilding
        let linked = Self.isLinked
        let me = Self.thisMacID
        let main = settings.mainMacId.flatMap { $0.isEmpty ? nil : $0 }
        let step = MainMac.step(
            linked: linked, runsHere: ServiceStation.runsService, mainMacId: main, lastSeen: lastSeen, thisMac: me)
        switch step {
        case .none:
            break
        case .setRunsHere(let on):
            ServiceStation.runsService = on
            DiagnosticsStore.shared.note("mainMac.follow", detail: on ? "this Mac is the Main Mac" : "Main Mac is \(settings.mainMacName ?? "another Mac")")
        case .claim:
            if let lastClaim, Date().timeIntervalSince(lastClaim) < Self.claimPatience { break }
            lastClaim = .now
            let name = Self.thisMacName
            model.updateSlideBuilding { settings in
                settings.mainMacId = me
                settings.mainMacName = name
            }
            DiagnosticsStore.shared.note("mainMac.claim", detail: name)
        case .release:
            model.updateSlideBuilding { settings in
                guard settings.mainMacId == me else { return }
                settings.mainMacId = nil
                settings.mainMacName = nil
            }
            DiagnosticsStore.shared.note("mainMac.release")
        }
        if linked { lastSeen = .some(main) } else { lastSeen = nil }
        if main == me { lastClaim = nil }
        role = MainMac.role(linked: linked, runsHere: ServiceStation.runsService, mainMacId: main, thisMac: me)
        mainMacName = main == nil ? nil : settings.mainMacName
    }
}

// MARK: Settings

/// Settings › General: this Mac's role, which Mac is main, and Make This
/// the Main Mac.
struct MainMacRoleRow: View {
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let coordinator = MainMacCoordinator.shared
        LabeledContent("This Mac's role") {
            HStack(spacing: 8) {
                Text(coordinator.role.title).fontWeight(.semibold)
                if coordinator.role == .editor {
                    Button("Make This the Main Mac") { coordinator.makeThisMacMain() }
                        .disabled(runOnly)
                        .help("This Mac runs the countdowns, the pre-service restarts and the phone remote; the Main Mac now steps down")
                }
            }
        }
        Text(Self.caption(role: coordinator.role, mainMacName: coordinator.mainMacName))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func caption(role: MainMac.Role, mainMacName: String?) -> String {
        switch role {
        case .main:
            "This Mac runs the service for every Mac linked to the church library."
        case .editor:
            "Edits the church library with every other Mac. "
                + (mainMacName.map { "\($0) runs the service." } ?? "No Mac runs the service yet.")
        case .onItsOwn:
            "Not linked (Settings › Integrations › Sync): this Mac has its own library and runs its own service, apart from the church's Macs."
        }
    }
}
