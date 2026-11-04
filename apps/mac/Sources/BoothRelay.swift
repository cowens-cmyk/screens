import AppKit
import Foundation
import LocalAPI
import Observation
import QuartzCore
import RenderEngine
import Security

/// Sends the show to the booth board in the Hope CMS (dashboard.hopejc.org/booth),
/// the TV in the green room and the sound booth: the live slide and what's
/// next, the stage display's mode, the timers, any stage message, and a
/// picture of the audience screen.
///
/// The CMS can't reach this Mac, so the Mac pushes: the state whenever it
/// changes and every 5 seconds regardless (the board calls Screens "not heard
/// from" after 20), the picture when the audience screen changes. The board
/// counts the timers down itself between pushes, so a running timer alone
/// doesn't send anything.
///
/// Kept per Mac and off until turned on, so only the Mac running the service
/// sends. The token comes from the Booth page in the CMS and is kept in the
/// Keychain. With no network nothing is kept or retried: the next tick sends
/// the state as it is then.
@MainActor
@Observable
final class BoothRelay {
    static let shared = BoothRelay()

    static let enabledKey = "booth.enabled"
    static let addressKey = "booth.address"
    static let defaultAddress = "https://dashboard.hopejc.org"

    private static let tickSeconds: TimeInterval = 1
    private static let heartbeatSeconds: TimeInterval = 5
    /// The picture is sent again now and then even when it hasn't changed:
    /// the CMS keeps it in memory only, and loses it when it restarts.
    private static let frameRefreshSeconds: TimeInterval = 60
    private static let frameWidth = 960

    /// When the CMS last took the state.
    private(set) var lastSent: Date?
    /// One short line for Settings when something is wrong.
    private(set) var problem: String?
    private(set) var hasToken = false

    /// Read from the Keychain once, not every second.
    @ObservationIgnored private var token: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var controls: ServiceControls?
    @ObservationIgnored private weak var render: RenderContext?
    @ObservationIgnored private weak var bridge: AppAPIBridge?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastShape: Data?
    @ObservationIgnored private var lastPush = Date.distantPast
    @ObservationIgnored private var lastFrameScene: RenderScene?
    @ObservationIgnored private var lastFramePush = Date.distantPast
    @ObservationIgnored private var sendingFrame = false
    @ObservationIgnored private let frames = RemoteFrames(width: BoothRelay.frameWidth)

    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {
        token = BoothTokenKeychain.load()
        hasToken = token != nil
    }

    var enabled: Bool {
        get {
            access(keyPath: \.lastSent)
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            problem = nil
            newValue ? startLoop() : stopLoop()
            lastSent = nil
        }
    }

    /// The CMS's address, for a test copy; the church's by default.
    var address: String {
        let stored = UserDefaults.standard.string(forKey: Self.addressKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? Self.defaultAddress : stored
    }

    func setToken(_ token: String?) {
        let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.isEmpty { BoothTokenKeychain.clear() } else { BoothTokenKeychain.save(clean) }
        self.token = clean.isEmpty ? nil : clean
        hasToken = token != nil
        problem = nil
        lastShape = nil
        lastFrameScene = nil
    }

    func attach(model: AppModel, controls: ServiceControls, render: RenderContext, bridge: AppAPIBridge) {
        self.model = model
        self.controls = controls
        self.render = render
        self.bridge = bridge
        if enabled { startLoop() }
    }

    private func startLoop() {
        guard loop == nil else { return }
        lastShape = nil
        lastFrameScene = nil
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Sending

    private func tick() async {
        guard let bridge, let token else {
            if token == nil { problem = "Paste the token from the Booth page in the CMS." }
            return
        }
        let payload = makePayload(bridge: bridge)
        let shape = Self.shape(of: payload)
        let now = Date()
        if shape != lastShape || now.timeIntervalSince(lastPush) >= Self.heartbeatSeconds {
            var stamped = payload
            stamped.sentAt = now.timeIntervalSince1970 * 1000
            if await send(path: "/api/booth/screens", method: "POST", body: Self.encode(stamped), type: "application/json", token: token) {
                lastShape = shape
                lastPush = now
            } else {
                // Try again next tick rather than in five seconds.
                lastShape = nil
            }
        }
        await sendFrameIfChanged(token: token)
    }

    private func sendFrameIfChanged(token: String) async {
        guard let render, !sendingFrame else { return }
        let scene = render.liveScene
        let stale = Date().timeIntervalSince(lastFramePush) >= Self.frameRefreshSeconds
        guard scene != lastFrameScene || stale else { return }
        sendingFrame = true
        defer { sendingFrame = false }
        // Drawn a few seconds ahead, as for the phone remote, so a slide
        // caught mid-fade isn't the one kept.
        guard let jpeg = await frames.jpeg(slot: "booth", scene: scene, at: CACurrentMediaTime() + 10, render: render) else { return }
        if await send(path: "/api/booth/screens/frame", method: "PUT", body: jpeg, type: "image/jpeg", token: token) {
            lastFrameScene = scene
            lastFramePush = Date()
        }
    }

    private func send(path: String, method: String, body: Data, type: String, token: String) async -> Bool {
        guard let url = URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            problem = "The CMS address isn't valid."
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200 ..< 300:
                problem = nil
                lastSent = Date()
                return true
            case 401:
                problem = "The CMS refused the token. Make a new one on the Booth page."
            case 503:
                problem = "The CMS can't keep the board's state right now."
            default:
                problem = "The CMS answered \(status)."
            }
        } catch {
            problem = "Can't reach the CMS."
        }
        return false
    }

    // MARK: What's sent

    private struct Payload: Encodable {
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
    }

    private func makePayload(bridge: AppAPIBridge) -> Payload {
        let setup = ShowSetup.shared
        let transport = bridge.transportRows()
        // A playing video takes the stage over (the Video layout) unless the
        // stage is set to keep its layout; looping backgrounds don't.
        let video = setup.stageShowsVideos ? transport.first { $0.playing && !$0.looping } : nil
        let layoutID = setup.stageLayoutOverride ?? StageLayouts.id(for: setup.stageMode)
        let layout = setup.stageMode == .mirror
            ? nil
            : model?.resident.confidenceLayouts.value(layoutID)?.name ?? StageLayouts.name(for: layoutID)
        return Payload(
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

    private static func encode(_ payload: Payload) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// What decides whether to send: everything but the send time, the
    /// running timers' and videos' ticking values (the board counts those
    /// itself) and the stage message's seconds left.
    private static func shape(of payload: Payload) -> Data {
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

/// The booth board token, in the Keychain on this Mac only.
enum BoothTokenKeychain {
    private static let service = "org.hopejc.screens.booth"
    private static let account = "token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String) {
        clear()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
