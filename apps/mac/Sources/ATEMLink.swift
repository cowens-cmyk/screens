import Foundation
import Network
import Observation
import PresenterCore
import RenderEngine
import SwiftUI

/// Puts the livestream graphics on and off air on the ATEM by itself.
///
/// Screens' Livestream screen goes into the switcher as Fill and Key, carried
/// by one keyer. With this on, the keyer is cut on the moment that screen has
/// something to show (a lower third, lyrics, a full slide, a video) and cut
/// off a moment after it's clear, so nobody keys anything by hand. Both cuts
/// land while the key signal is clear, so the slide's own fade is what the
/// stream sees.
///
/// It only reacts to changes: a keyer someone cuts on the switcher panel
/// stays that way until the stream's picture next changes. Per Mac and off
/// until someone turns it on here.
@MainActor
@Observable
final class ATEMLink {
    static let shared = ATEMLink()

    var enabled: Bool {
        didSet {
            save()
            if enabled != oldValue { restart() }
        }
    }
    var host: String {
        didSet {
            save()
            if host != oldValue, enabled { restart() }
        }
    }
    var keyer: ATEMProtocol.Keyer {
        didSet {
            save()
            if keyer != oldValue { follower = ATEMKeyFollower() }
        }
    }
    /// Cut the keyer by what the Livestream screen shows. Off leaves the
    /// connection up (for the status and the buttons) without touching it.
    var followsStream: Bool {
        didSet {
            save()
            if followsStream, !oldValue, connected { send(onAir: follower.wanted) }
        }
    }

    private(set) var state = ATEMProtocol.State()
    private(set) var connected = false
    private(set) var status = ""
    /// What the Livestream screen shows now, for the monitor's badge.
    private(set) var coverage: StreamCoverage = .transparent

    var keyerOnAir: Bool? { state.onAir[keyer] }

    @ObservationIgnored private var connection: ATEMConnection?
    @ObservationIgnored private var follower = ATEMKeyFollower()
    @ObservationIgnored private weak var render: RenderContext?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var provider: (target: String, scene: @Sendable () -> RenderScene)?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "atem.enabled")
        host = defaults.string(forKey: "atem.host") ?? ""
        keyer = defaults.string(forKey: "atem.keyer").flatMap(ATEMProtocol.Keyer.init(storageKey:))
            ?? .upstream(me: 0, keyer: 0)
        followsStream = defaults.object(forKey: "atem.followStream") as? Bool ?? true
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "atem.enabled")
        defaults.set(host, forKey: "atem.host")
        defaults.set(keyer.storageKey, forKey: "atem.keyer")
        defaults.set(followsStream, forKey: "atem.followStream")
    }

    func attach(render: RenderContext) {
        self.render = render
        restart()
    }

    private func restart() {
        connection?.stop()
        connection = nil
        watch?.cancel()
        watch = nil
        connected = false
        state = ATEMProtocol.State()
        follower = ATEMKeyFollower()
        guard enabled else {
            status = "Off."
            return
        }
        let address = host.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            status = "Enter the ATEM's IP address."
            return
        }
        status = "Connecting to \(address)…"
        let connection = ATEMConnection(host: address) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.connection = connection
        connection.start()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                self?.followStream()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func handle(_ event: ATEMConnection.Event) {
        switch event {
        case .connecting:
            connected = false
            state = ATEMProtocol.State()
            status = "Connecting to \(host)…"
        case .lost(let reason):
            connected = false
            status = reason
        case .commands(let commands):
            let wasReady = state.initialized
            for command in commands { state.apply(command) }
            if state.initialized, !wasReady {
                connected = true
                status = "Connected to \(state.productName ?? "the ATEM")."
                // A fresh connection puts the keyer where the stream says
                // it should be, so a restart mid-service can't leave a
                // graphic stuck on or missing.
                if followsStream { send(onAir: follower.wanted) }
            }
        }
    }

    private func followStream() {
        guard let render else { return }
        let target = ShowSetup.shared.streamTarget
        guard !target.isEmpty else {
            coverage = .transparent
            return
        }
        if provider?.target != target {
            provider = (target, render.outputs.previewProvider(for: target))
        }
        guard let scene = provider?.scene else { return }
        let next = StreamCoverage.classify(scene())
        if next != coverage { coverage = next }
        // Followed while disconnected too, so a reconnect puts the keyer
        // where the stream is now instead of blinking it off first.
        let change = follower.update(showing: next != .transparent, at: Date())
        if let change, followsStream, connected { send(onAir: change) }
    }

    /// Cuts the chosen keyer, from the settings' buttons or the follower.
    func send(onAir: Bool) {
        connection?.send([ATEMProtocol.setOnAir(keyer, onAir)])
    }
}

/// One UDP session with the switcher, confined to its own queue: the hello,
/// acknowledging everything the switcher sends, resending our commands until
/// they're acknowledged, and starting over when it goes quiet.
final class ATEMConnection: @unchecked Sendable {
    enum Event: Sendable {
        case connecting
        case lost(String)
        case commands([ATEMProtocol.Command])
    }

    private let host: String
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "org.hopejc.screens.atem")

    private var udp: NWConnection?
    private var timer: DispatchSourceTimer?
    private var sessionID: UInt16 = 0
    private var established = false
    private var helloSentAt = Date.distantPast
    private var lastHeard = Date.distantPast
    private var lastPing = Date.distantPast
    private var nextPacketID: UInt16 = 1
    private var unacknowledged: [UInt16: (packet: ATEMProtocol.Packet, sentAt: Date, tries: Int)] = [:]
    private var stopped = false

    /// The switcher sends state changes as they happen and little else, so
    /// we ask for an acknowledgement once a second to know it's still there.
    private static let pingEvery: TimeInterval = 1
    private static let quietLimit: TimeInterval = 4
    private static let resendAfter: TimeInterval = 0.25
    private static let maxTries = 8

    init(host: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.host = host
        self.onEvent = onEvent
    }

    func start() {
        queue.async { self.open() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.udp?.cancel()
            self.udp = nil
        }
    }

    func send(_ commands: [ATEMProtocol.Command]) {
        queue.async {
            guard self.established else { return }
            let id = self.nextPacketID
            self.nextPacketID = id >= 0x7FFF ? 1 : id + 1
            let packet = ATEMProtocol.Packet(
                flags: .ackRequest, sessionID: self.sessionID, packetID: id,
                payload: ATEMProtocol.encode(commands))
            self.unacknowledged[id] = (packet, Date(), 1)
            self.write(packet)
        }
    }

    private func open() {
        guard !stopped else { return }
        udp?.cancel()
        established = false
        unacknowledged = [:]
        nextPacketID = 1
        onEvent(.connecting)
        guard let port = NWEndpoint.Port(rawValue: ATEMProtocol.port) else { return }
        let udp = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        self.udp = udp
        udp.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.sayHello() }
        }
        receive(on: udp)
        udp.start(queue: queue)
    }

    private func sayHello() {
        sessionID = UInt16.random(in: 0x1000..<0x7FFF)
        helloSentAt = Date()
        write(ATEMProtocol.hello(sessionID: sessionID))
    }

    private func receive(on udp: NWConnection) {
        udp.receiveMessage { [weak self] data, _, _, error in
            guard let self, udp === self.udp else { return }
            if let data, let packet = ATEMProtocol.Packet.decode(data) { self.handle(packet) }
            if error == nil { self.receive(on: udp) }
        }
    }

    private func handle(_ packet: ATEMProtocol.Packet) {
        lastHeard = Date()
        if packet.flags.contains(.hello) {
            sessionID = packet.sessionID
            write(ATEMProtocol.ack(sessionID: sessionID, packetID: 0))
            return
        }
        sessionID = packet.sessionID
        established = true
        if packet.flags.contains(.ackRequest) {
            write(ATEMProtocol.ack(sessionID: sessionID, packetID: packet.packetID))
        }
        if packet.flags.contains(.ackReply) {
            unacknowledged[packet.ackID] = nil
        }
        let commands = ATEMProtocol.commands(in: packet.payload)
        if !commands.isEmpty { onEvent(.commands(commands)) }
    }

    private func tick() {
        guard !stopped, udp != nil else { return }
        let now = Date()
        if !established {
            // No answer to the hello: the switcher is off, unplugged, or
            // already has as many clients as it takes.
            if now.timeIntervalSince(helloSentAt) > 2 {
                onEvent(.lost("No answer from \(host). Check the address and that the ATEM is on."))
                sayHello()
            }
            return
        }
        if now.timeIntervalSince(lastHeard) > Self.quietLimit {
            onEvent(.lost("Lost the ATEM at \(host). Reconnecting…"))
            open()
            return
        }
        for (id, entry) in unacknowledged where now.timeIntervalSince(entry.sentAt) > Self.resendAfter {
            guard entry.tries < Self.maxTries else {
                onEvent(.lost("The ATEM stopped answering. Reconnecting…"))
                open()
                return
            }
            var again = entry.packet
            again.flags.insert(.retransmit)
            unacknowledged[id] = (entry.packet, now, entry.tries + 1)
            write(again)
        }
        if now.timeIntervalSince(lastPing) > Self.pingEvery {
            lastPing = now
            let id = nextPacketID
            nextPacketID = id >= 0x7FFF ? 1 : id + 1
            write(ATEMProtocol.Packet(flags: .ackRequest, sessionID: sessionID, packetID: id))
        }
    }

    private func write(_ packet: ATEMProtocol.Packet) {
        udp?.send(content: packet.encoded, completion: .contentProcessed { _ in })
    }
}

/// Settings › Integrations › ATEM.
struct ATEMSettingsForm: View {
    @Bindable private var link = ATEMLink.shared
    @State private var address = ATEMLink.shared.host

    var body: some View {
        Section {
            Toggle("Connect to the ATEM", isOn: $link.enabled)
                .toggleStyle(.switch)
                .settingsAnchor("atem.link")
            LabeledContent("Address") {
                HStack(spacing: 8) {
                    TextField("", text: $address, prompt: Text("10.1.2.12"))
                        .labelsHidden()
                        .frame(width: 140)
                        .onSubmit { link.host = address }
                    Button("Connect") { link.host = address }
                        .disabled(address == link.host)
                }
            }
            LabeledContent("Status") {
                Text(link.status).foregroundStyle(.secondary)
            }
        } header: {
            Text("ATEM")
        }
        Section {
            Toggle("Put graphics on and off air with the slides", isOn: $link.followsStream)
                .toggleStyle(.switch)
            Picker("Keyer", selection: $link.keyer) {
                ForEach(keyerChoices, id: \.self) { keyer in
                    Text(keyerTitle(keyer)).tag(keyer)
                }
            }
            LabeledContent("Now") {
                Text(nowText).foregroundStyle(.secondary)
            }
            LabeledContent("Test") {
                HStack(spacing: 8) {
                    Button("Put On Air") { link.send(onAir: true) }
                    Button("Take Off Air") { link.send(onAir: false) }
                }
                .disabled(!link.connected)
            }
        } header: {
            Text("Livestream Graphics")
        } footer: {
            Text("The keyer carries the Livestream screen's Fill and Key. It goes on air as soon as that screen shows something (a lower third, lyrics, a full slide or a video) and off a moment after it's clear. Cutting it on the switcher still works; Screens changes it again at the next slide that changes what the stream shows.")
        }
    }

    private var keyerChoices: [ATEMProtocol.Keyer] {
        let reported = link.state.keyers
        return reported.contains(link.keyer) ? reported : [link.keyer] + reported
    }

    private func keyerTitle(_ keyer: ATEMProtocol.Keyer) -> String {
        guard let sources = link.state.sources[keyer] else { return keyer.title }
        return "\(keyer.title) (\(link.state.inputName(sources.fill)) / \(link.state.inputName(sources.key)))"
    }

    private var nowText: String {
        let stream = switch link.coverage {
        case .transparent: "The Livestream screen is clear"
        case .lowerThird: "The Livestream screen shows graphics"
        case .fullScreen: "The Livestream screen is full screen"
        }
        guard link.connected, let onAir = link.keyerOnAir else { return stream + "." }
        return stream + "; the keyer is " + (onAir ? "on air." : "off air.")
    }
}

/// The Livestream monitor's tally: whether the ATEM keyer carrying the
/// graphics is on air. Click to cut it on or off by hand.
struct ATEMKeyerChip: View {
    private let link = ATEMLink.shared

    var body: some View {
        if link.enabled {
            let onAir = link.connected ? link.keyerOnAir : nil
            Button {
                if let onAir { link.send(onAir: !onAir) }
            } label: {
                Text(onAir == nil ? "ATEM" : onAir == true ? "On Air" : "Off Air")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(onAir == true ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(onAir == true ? Color.red : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .disabled(onAir == nil)
            .help(onAir == nil
                  ? "Not connected to the ATEM. \(link.status)"
                  : "The ATEM keyer carrying the livestream graphics (\(link.keyer.title)). Click to cut it \(onAir == true ? "off" : "on").")
        }
    }
}
