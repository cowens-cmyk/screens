import Foundation
import LocalAPI
import PresenterCore

/// What's live, as the booth board (BoothRelay, POST /api/booth/screens)
/// and the phone remote in the CMS (PhoneRemoteController, over the sync
/// socket) are told it: the live slide and what's next, the stage
/// display's mode, the timers, any stage message and the videos playing.
/// The remote's copy adds what's live by id, the action combos and this
/// Mac's name.
struct ShowStatePayload: Encodable {
    struct App: Encodable {
        var version: String
        var host: String
    }

    struct Stage: Encodable {
        var mode: String
        var title: String
        var layout: String?
        var video: Bool
        var videoName: String?
    }

    var sentAt: Double = 0
    var app: App
    var status: APIShowStatus
    var timers: [APITimerStatus]
    var transport: [APITransportRow]
    var stage: Stage
    /// The phone remote's only.
    var ids: PhoneRemote.LiveIDs?
    var combos: [PhoneRemote.Combo]?
    var deviceName: String?

    @MainActor
    static func make(bridge: AppAPIBridge, model: AppModel?) -> ShowStatePayload {
        let setup = ShowSetup.shared
        let transport = bridge.transportRows()
        // A playing video takes the stage over (the Video layout) unless the
        // stage is set to keep its layout; looping backgrounds don't.
        let video = setup.stageShowsVideos ? transport.first { $0.playing && !$0.looping } : nil
        let layoutID = setup.stageLayoutOverride ?? StageLayouts.id(for: setup.stageMode)
        let layout = setup.stageMode == .mirror
            ? nil
            : model?.resident.confidenceLayouts.value(layoutID)?.name ?? StageLayouts.name(for: layoutID)
        return ShowStatePayload(
            app: .init(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                host: Host.current().localizedName ?? ""),
            status: bridge.showStatus(),
            timers: bridge.timers(),
            transport: transport,
            stage: .init(
                mode: setup.stageMode.rawValue, title: setup.stageMode.title,
                layout: layout, video: video != nil, videoName: video?.name))
    }

    static func encode(_ payload: ShowStatePayload) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// What decides whether to send: everything but the send time, the
    /// running timers' and videos' ticking values (the board counts those
    /// itself) and the stage message's seconds left.
    static func shape(of payload: ShowStatePayload) -> Data {
        var p = payload
        p.sentAt = 0
        p.timers = p.timers.map { timer in
            var t = timer
            if t.running { t.displaySeconds = 0 }
            return t
        }
        p.transport = p.transport.map { row in
            var r = row
            r.position = 0
            return r
        }
        p.status.alert?.secondsLeft = nil
        return encode(p)
    }
}
