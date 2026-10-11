import CoreVideo
import Foundation
import IOSurface
import RenderEngine

/// App side of one DeckLink capture. The capture itself runs in the DeckLink XPC helper (the
/// same process that drives DeckLink outputs, so a Desktop Video driver fault never takes the
/// show down); the helper pushes each converted BGRA frame back as an IOSurface over this
/// client's exported `DeckLinkInputClientProtocol`. Status is polled once a second, and a lost
/// helper or a failed open is retried every few seconds, so boot order and replugs don't matter.
final class DeckLinkInputClient: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case starting
        case noSignal
        case receiving(format: String)
        case failed(String)

        var text: String {
            switch self {
            case .starting: "Starting\u{2026}"
            case .noSignal: "No signal"
            case .receiving(let format): format
            case .failed(let message): message
            }
        }
    }

    let persistentID: Int64
    let name: String

    private let receiver = DeckLinkInputFrameReceiver()
    private let stateBox = Locked<State>(.starting)
    private let queue = DispatchQueue(label: "decklink.input.client", qos: .userInitiated)

    // Touched only on `queue`.
    private var connection: NSXPCConnection?
    private var generation = 0
    private var stopped = false
    private var pollTimer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var lastStatusReply: TimeInterval = 0
    private var lastLogged = ""

    private static let retrySeconds: Double = 4
    private static let statusTimeout: Double = 6

    init(persistentID: Int64, name: String) {
        self.persistentID = persistentID
        self.name = name
    }

    var state: State { stateBox.value }

    func latestFrame() -> CVPixelBuffer? { receiver.latest.value }

    func start() {
        queue.async { [self] in connect() }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            teardown(stopRemote: true)
            receiver.latest.value = nil
        }
    }

    // MARK: Connection (on `queue`)

    private func connect() {
        guard !stopped else { return }
        teardown(stopRemote: false)
        generation += 1
        let current = generation
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: DeckLinkInputClientProtocol.self)
        connection.exportedObject = receiver
        let lost: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.connectionLost(generation: current) }
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        connection.resume()
        self.connection = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in lost() })
            as? DeckLinkHelperProtocol
        else {
            fail("DeckLink helper unavailable", generation: current)
            return
        }
        lastStatusReply = ProcessInfo.processInfo.systemUptime
        proxy.startInput(devicePersistentID: persistentID) { @Sendable [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == current, !self.stopped else { return }
                if let error {
                    self.fail(error, generation: current)
                } else {
                    self.log("capturing")
                    self.startPolling(generation: current)
                }
            }
        }
    }

    private func startPolling(generation current: Int) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 1)
        timer.setEventHandler { [weak self] in self?.poll(generation: current) }
        timer.resume()
        pollTimer = timer
    }

    private func poll(generation current: Int) {
        guard generation == current, !stopped,
            let proxy = connection?.remoteObjectProxy as? DeckLinkHelperProtocol
        else { return }
        if ProcessInfo.processInfo.systemUptime - lastStatusReply > Self.statusTimeout {
            // The helper stopped answering (a wedged driver call): drop this connection and open a
            // fresh one. The helper process is shared with DeckLink outputs, so it is not killed here.
            fail("DeckLink helper not responding", generation: current)
            return
        }
        proxy.inputStatus { @Sendable [weak self] data in
            guard let self,
                let status = try? JSONDecoder().decode(DeckLinkHelperInputStatus.self, from: data)
            else { return }
            self.queue.async {
                guard self.generation == current, !self.stopped else { return }
                self.lastStatusReply = ProcessInfo.processInfo.systemUptime
                self.apply(status, generation: current)
            }
        }
    }

    private func apply(_ status: DeckLinkHelperInputStatus, generation current: Int) {
        switch status.signal {
        case .starting:
            stateBox.value = .starting
        case .noSignal:
            stateBox.value = .noSignal
            receiver.latest.value = nil
            log("no signal")
        case .receiving:
            let format = status.format ?? "Receiving"
            stateBox.value = .receiving(format: format)
            log("receiving \(format)")
        case .failed:
            fail(status.error ?? "capture failed", generation: current)
        }
    }

    private func connectionLost(generation current: Int) {
        guard generation == current, !stopped else { return }
        fail("DeckLink helper restarted", generation: current)
    }

    private func fail(_ message: String, generation current: Int) {
        guard generation == current, !stopped else { return }
        stateBox.value = .failed(message)
        receiver.latest.value = nil
        log(message)
        teardown(stopRemote: true)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        queue.asyncAfter(deadline: .now() + Self.retrySeconds, execute: work)
    }

    private func teardown(stopRemote: Bool) {
        retry?.cancel()
        retry = nil
        pollTimer?.cancel()
        pollTimer = nil
        guard let connection else { return }
        self.connection = nil
        // Bump the generation first so this connection's own invalidation is ignored.
        generation += 1
        if stopRemote, let proxy = connection.remoteObjectProxy as? DeckLinkHelperProtocol {
            proxy.stopInput()
        }
        connection.invalidate()
    }

    private func log(_ line: String) {
        guard line != lastLogged else { return }
        lastLogged = line
        DiagnosticsStore.shared.note("input.decklink", detail: "\(name): \(line)")
    }
}

/// Receives frames from the helper. Each surface's global use count is raised for as long as
/// the app holds its pixel buffer (renderer, input delay copy), so the helper's capture ring
/// never reuses a surface that is still on screen.
final class DeckLinkInputFrameReceiver: NSObject, DeckLinkInputClientProtocol, @unchecked Sendable {
    let latest = Locked<CVPixelBuffer?>(nil)

    func inputFrame(_ surface: IOSurface, reply: @escaping () -> Void) {
        defer { reply() }
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
            let buffer = unmanaged?.takeRetainedValue()
        else { return }
        CVBufferSetAttachment(
            buffer, "MxUDeckLinkSurfaceLease" as CFString, SurfaceLease(surfaceRef),
            .shouldNotPropagate)
        latest.value = buffer
    }
}

/// Holds an IOSurface's use count up until the pixel buffer it is attached to goes away.
private final class SurfaceLease: NSObject, @unchecked Sendable {
    private let surface: IOSurfaceRef

    init(_ surface: IOSurfaceRef) {
        self.surface = surface
        IOSurfaceIncrementUseCount(surface)
    }

    deinit {
        IOSurfaceDecrementUseCount(surface)
    }
}
