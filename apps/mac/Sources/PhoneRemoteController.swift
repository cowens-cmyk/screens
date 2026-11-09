import Foundation
import LocalAPI
import PresenterCore

/// The phone remote in the CMS (Sunday › Screens › Remote), on this Mac:
/// its taps arrive over the sync socket (CloudSync) and are done the way
/// the Wi-Fi remote's are, through the Local API's bridge, and what's live
/// goes back the same way for the phone to show.
///
/// Only the Mac that runs the service (Run on this Mac) follows the phone,
/// and only while "Phone remote" is on in Settings › Integrations › Sync.
/// Every other Mac stays quiet: it neither answers nor says what's live, so
/// the hub only ever hears the one.
@MainActor
final class PhoneRemoteController {
    static let shared = PhoneRemoteController()

    static let enabledKey = "remote.cloudCommands"

    /// On unless turned off on this Mac.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// This Mac is the one the phone drives.
    static var follows: Bool { enabled && ServiceStation.runsService }

    private weak var model: AppModel?
    private var bridge: AppAPIBridge?
    private var loop: Task<Void, Never>?
    private var lastShape: Data?
    private var lastSent = Date.distantPast

    private init() {}

    func attach(model: AppModel, bridge: AppAPIBridge) {
        self.model = model
        self.bridge = bridge
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The socket is (re)connected: the hub is told what's live at once.
    func connected() {
        lastShape = nil
        Task { await tick() }
    }

    // MARK: Taps

    func handle(_ request: PhoneRemote.Request) async {
        guard Self.follows, let bridge else { return }
        var ok = true
        var message: String?
        switch request.command {
        case .failure(let failure):
            ok = false
            message = failure.message
        case .success(let command):
            do {
                try await perform(command, bridge: bridge)
                DiagnosticsStore.shared.note("remote.cloud", detail: String(describing: command))
            } catch let error as APIError {
                ok = false
                message = error.message
            } catch {
                ok = false
                message = "That didn't work on the Mac."
            }
        }
        _ = await CloudSync.shared.send(.remoteDone(id: request.id, ok: ok, message: message))
        // The phone sees the result straight away rather than on the next
        // heartbeat.
        lastShape = nil
        await tick()
    }

    private func perform(_ command: PhoneRemote.Command, bridge: AppAPIBridge) async throws {
        switch command {
        case .advance(let steps):
            try await bridge.advance(steps: steps, settled: false)
        case .slide(let presentationId, let slideId, let serviceId, let itemId, let index):
            try await bridge.fireRemoteSlide(
                presentationId: presentationId, slideId: slideId, serviceId: serviceId, itemId: itemId, index: index)
        case .item(let serviceId, let itemId):
            try await bridge.fireRemoteItem(serviceId: serviceId, itemId: itemId)
        case .clear(let function):
            if function == "all" { bridge.clearAll() } else { try bridge.clear(APIClearCommand(function: function)) }
        case .timer(let id, let action):
            let api: APITimerAction = switch action {
            case .start: .play
            case .stop: .pause
            case .reset: .reset
            }
            try bridge.timerAction(id: id, action: api)
        case .combo(let id):
            try bridge.fireActionCombo(id: id)
        case .alert(let message):
            // As the Wi-Fi remote sends it: on the stage display until cleared.
            try bridge.fireAlert(APIFireAlertCommand(message: message, behavior: "persist", target: "confidence"))
        case .alertDismiss:
            bridge.dismissAlert()
        case .service(let id):
            try bridge.selectService(id: id)
        }
    }

    // MARK: What's live

    private func tick() async {
        guard Self.follows, CloudSync.shared.status == .live, let bridge else {
            lastShape = nil
            return
        }
        var payload = ShowStatePayload.make(bridge: bridge, model: model)
        let live = payload.status.liveSlide
        let itemId = live?.serviceItemId
        payload.ids = PhoneRemote.LiveIDs(
            serviceId: itemId == nil ? nil : payload.status.currentServiceId,
            itemId: itemId, presentationId: live?.presentationId,
            slideId: live?.slideId, slideIndex: live?.slideIndex)
        payload.combos = (model?.actionCombos ?? []).prefix(PhoneRemote.comboLimit).map { PhoneRemote.Combo(id: $0.id, name: $0.name) }
        payload.deviceName = CloudSync.shared.deviceName ?? Host.current().localizedName
        let shape = ShowStatePayload.shape(of: payload)
        let now = Date()
        guard shape != lastShape || now.timeIntervalSince(lastSent) >= PhoneRemote.heartbeatSeconds else { return }
        payload.sentAt = now.timeIntervalSince1970 * 1000
        var data = ShowStatePayload.encode(payload)
        if data.count > PhoneRemote.liveLimit {
            // A very long slide or many videos: the words and the lists go
            // before the state does.
            payload.status.liveSlide?.text = nil
            payload.combos = []
            payload.transport = []
            data = ShowStatePayload.encode(payload)
            guard data.count <= PhoneRemote.liveLimit else { return }
        }
        if await CloudSync.shared.send(.live(state: data)) {
            lastShape = shape
            lastSent = now
        } else {
            lastShape = nil
        }
    }
}
