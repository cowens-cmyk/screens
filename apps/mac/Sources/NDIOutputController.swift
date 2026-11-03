import CoreVideo
import Foundation
import IOSurface
import Observation
import OutputEngine
import RenderEngine

@MainActor
@Observable
final class NDIOutputController {
    enum Status: Equatable {
        case idle
        case starting
        case sending(sourceName: String)
        case failed(String)

        case interrupted(sourceName: String)
    }

    private(set) var status: Status = .idle
    private(set) var targetID = ""
    private(set) var targetName = ""

    private var sourceRect: CGRect?

    private var placement: CGRect?

    private let render: RenderContext
    private var mirror: OutputMirror?
    private var connection: NSXPCConnection?

    private var connectionGeneration = 0

    private struct StartParameters {
        var sourceName: String
        var width: Int
        var height: Int
        var frameRate: Int
        var keying: OutputKeying
    }

    /// What the sender was started with, so a helper restart can start it
    /// again as it was.
    private var startParameters: StartParameters?
    private var restartTask: Task<Void, Never>?

    init(render: RenderContext) {
        self.render = render
    }

    var isActive: Bool {
        switch status {
        case .starting, .sending, .interrupted: true
        case .idle, .failed: false
        }
    }

    func start(
        targetID: String, targetName: String, sourceName: String,
        width: Int, height: Int, frameRate: Int,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        keying: OutputKeying = .fullPicture
    ) {
        stop()
        self.targetID = targetID
        self.targetName = targetName
        self.sourceRect = sourceRect
        self.placement = placement
        startParameters = StartParameters(
            sourceName: sourceName, width: width, height: height,
            frameRate: frameRate, keying: keying)
        status = .starting

        connectionGeneration += 1
        let generation = connectionGeneration
        let connection = NSXPCConnection(serviceName: NDIHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NDIHelperProtocol.self)

        // The helper crashed or restarted. The frames waiting for a reply
        // never get one, so their in-flight slots are gone with them: the
        // sender starts again on a new connection with a new mirror.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation,
                      self.isActive
                else { return }
                self.status = .interrupted(sourceName: sourceName)
                self.scheduleRestart(after: generation)
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }

                DiagnosticsStore.shared.note(
                    "ndi.helper",
                    detail: "connection invalidated — service unreachable")
                guard self.isActive else { return }
                self.status = .failed("helper unreachable (connection invalidated)")
                self.stopMirror()
            }
        }
        connection.resume()
        self.connection = connection

        let remoteObject = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            // Calls still waiting when the helper goes down fail with
            // "interrupted"; the interruption handler restarts for those.
            let nsError = error as NSError
            let interrupted = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSXPCConnectionInterrupted
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation, !interrupted
                else { return }
                DiagnosticsStore.shared.note(
                    "ndi.helper", detail: "proxy error: \(error)")
                guard self.isActive else { return }
                self.status = .failed(error.localizedDescription)
                self.stopMirror()
            }
        }
        guard let proxy = remoteObject as? NDIHelperProtocol else {
            status = .failed("helper connection unavailable")
            return
        }
        proxy.startSender(
            name: sourceName,
            frameRateNumerator: Int32(frameRate * 1000),
            frameRateDenominator: 1000
        ) { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = .failed(error)
                    self.stopMirror()
                    return
                }
                self.status = .sending(sourceName: sourceName)
            }
        }

        let provider = render.outputs.previewProvider(for: targetID)

        nonisolated(unsafe) let remote = proxy
        let inFlight = Locked(0)
        mirror = OutputMirror(
            compositor: render.compositor,
            width: width, height: height, framesPerSecond: frameRate,
            transparentBackground: keying.transparentBackground,
            straightAlpha: keying.straightAlpha,
            provider: provider,
            delayFrames: render.outputs.videoDelayProvider(for: targetID),

            adjustments: render.outputs.adjustmentsProvider(for: targetID),
            sourceRect: sourceRect,
            placement: placement,
            mask: render.outputs.maskProvider(for: targetID),
            activityLabel: "NDI \(targetName)",
            sink: { pixelBuffer, _ in
                guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?
                    .takeUnretainedValue()
                else { return }
                let claimed = inFlight.withLock { count -> Bool in
                    guard count < 2 else { return false }
                    count += 1
                    return true
                }
                guard claimed else { return }
                let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
                remote.sendFrame(surface) {
                    inFlight.withLock { $0 -= 1 }
                }
            }
        )
        mirror?.start()
    }

    /// A short wait before starting again, so a helper that dies on start
    /// isn't relaunched in a tight loop.
    private func scheduleRestart(after generation: Int) {
        guard restartTask == nil else { return }
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  self.connectionGeneration == generation, self.isActive,
                  let parameters = self.startParameters
            else { return }
            self.start(
                targetID: self.targetID, targetName: self.targetName,
                sourceName: parameters.sourceName,
                width: parameters.width, height: parameters.height,
                frameRate: parameters.frameRate,
                sourceRect: self.sourceRect,
                placement: self.placement,
                keying: parameters.keying)
        }
    }

    func reloadNetworkPin() {
        guard isActive,
              let proxy = connection?.remoteObjectProxy as? NDIHelperProtocol
        else { return }
        proxy.reloadNetworkPin { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let error, self.isActive else { return }
                DiagnosticsStore.shared.note("ndi.helper", detail: "pin reload: \(error)")
                self.status = .failed(error)
                self.stopMirror()
            }
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        stopMirror()
        if let proxy = connection?.remoteObjectProxy as? NDIHelperProtocol {
            proxy.stopSender()
        }
        connection?.invalidate()
        connection = nil
        status = .idle
    }

    private func stopMirror() {
        mirror?.stop()
        mirror = nil
    }
}
