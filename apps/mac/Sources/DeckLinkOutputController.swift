import CoreVideo
import Foundation
import IOSurface
import Observation
import OutputEngine
import RenderEngine

/// One DeckLink port sending one screen (or a packed frame of several)
/// through the helper. Once asked to send it keeps at it until stopped: an
/// OutputKeeper decides when an attempt has failed and when to try again,
/// and this carries those steps out on the XPC connection.
@MainActor
@Observable
final class DeckLinkOutputController {
    enum Status: Equatable {
        case idle
        case starting
        case sending(deviceName: String)
        /// Not sending, and why. It is still trying.
        case failed(String)

        case interrupted(deviceName: String)
    }

    private(set) var status: Status = .idle
    private(set) var targetID = ""
    private(set) var targetName = ""

    private(set) var wireDetail = ""

    private struct Request {
        var devicePersistentID: Int64
        var deviceName: String
        var keying: DeckLinkAlphaKey
        var width: Int
        var height: Int
        var frameRate: Int
        var modeID: Int64
        var sourceRect: CGRect?
        var placement: CGRect?
        var composite: [OutputMirror.CompositeLayer]
    }

    private let render: RenderContext
    private var request: Request?
    private var keeper = OutputKeeper()
    private var mirror: OutputMirror?
    private var connection: NSXPCConnection?

    /// Bumped whenever an attempt ends, so replies and handlers from an
    /// earlier connection can't touch the current one. A late failure
    /// reply from a replaced connection used to mark a good port failed and
    /// stop its frames, with nothing left to start it again.
    private var attempt = 0

    /// When this attempt's mirror last handed over a frame (taken or not)
    /// and when the helper last took one. Written on the frame queues, read
    /// by the once-a-second check.
    private var lastOffered = Locked<TimeInterval?>(nil)
    private var lastAccepted = Locked<TimeInterval?>(nil)

    private var supervisor: Task<Void, Never>?
    private var lastLoggedProblem: String?

    init(render: RenderContext) {
        self.render = render
    }

    /// Asked to send and not stopped, whether or not frames are landing
    /// right now.
    var isActive: Bool { request != nil }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(
        targetID: String, targetName: String,
        devicePersistentID: Int64, deviceName: String, keying: DeckLinkAlphaKey,
        width: Int, height: Int, frameRate: Int, modeID: Int64 = 0,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        composite: [OutputMirror.CompositeLayer] = []
    ) {
        stop()
        self.targetID = targetID
        self.targetName = targetName
        request = Request(
            devicePersistentID: devicePersistentID, deviceName: deviceName,
            keying: keying, width: width, height: height, frameRate: frameRate,
            modeID: modeID, sourceRect: sourceRect, placement: placement,
            composite: composite)
        DiagnosticsStore.shared.note(
            "decklink.start",
            detail: "\(deviceName): asked to send \(width)×\(height)@\(frameRate)"
                + (modeID != 0 ? " mode \(modeID)" : " (Auto mode)"))
        startSupervisor()
        perform(keeper.begin(at: Self.now))
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        let wasRunning = request != nil
        request = nil
        keeper.stop()
        endAttempt(stopHelperOutput: true)
        lastLoggedProblem = nil
        status = .idle
        if wasRunning {
            DiagnosticsStore.shared.note("decklink.stop", detail: targetName)
        }
    }

    /// Tries again now instead of waiting out the rest of a retry, for when
    /// the reason to wait has likely gone (the device just showed up).
    func retrySoon() {
        guard request != nil else { return }
        keeper.retrySoon(at: Self.now)
        supervise()
    }

    // MARK: Steps

    private func startSupervisor() {
        supervisor?.cancel()
        supervisor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.supervise()
            }
        }
    }

    private func supervise() {
        guard request != nil else { return }
        let wasSending = keeper.isSending
        let step = keeper.tick(
            at: Self.now, lastOffered: lastOffered.value, lastAccepted: lastAccepted.value)
        if !wasSending, keeper.isSending { noteSending() }
        perform(step)
    }

    private func perform(_ step: OutputKeeper.Step) {
        switch step {
        case .none:
            break
        case .open:
            openAttempt()
        case .abandon(let reason, let killHelper):
            let helperPID = connection?.processIdentifier ?? 0
            endAttempt(stopHelperOutput: true)
            noteProblem(reason)
            // A call stuck inside the driver can't be cancelled; only a new
            // helper process gets past it. Every port and input on the
            // helper reconnects after this, which is why it is kept for an
            // open that never answers or opens that never take a frame.
            if killHelper, helperPID > 0 {
                DiagnosticsStore.shared.note(
                    "decklink.reconnect",
                    detail: "helper \(helperPID) wedged — killing it")
                kill(helperPID, SIGKILL)
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard let request else {
            status = .idle
            return
        }
        switch keeper.phase {
        case .stopped:
            status = .idle
        case .sending:
            status = .sending(deviceName: request.deviceName)
        case .opening, .confirming, .waiting:
            // One fault is often just the driver settling at launch; from
            // the second the reason is worth showing.
            if keeper.failures >= 2, let problem = keeper.problem {
                status = .failed("\(problem) — retrying")
            } else if keeper.hasSent {
                status = .interrupted(deviceName: request.deviceName)
            } else {
                status = .starting
            }
        }
    }

    private func noteSending() {
        guard let request else { return }
        DiagnosticsStore.shared.note(
            "decklink.start",
            detail: "\(request.deviceName): sending \(wireDetail)"
                + (keeper.failures > 0 ? " (after \(keeper.failures) retries)" : ""))
        lastLoggedProblem = nil
    }

    /// A port that can't start retries every few seconds for as long as it
    /// is assigned; the breadcrumbs get the first few faults, any change of
    /// reason, and a reminder now and then, not every retry.
    private func noteProblem(_ reason: String) {
        guard let request else { return }
        let failures = keeper.failures
        guard failures <= 3 || reason != lastLoggedProblem || failures % 30 == 0 else { return }
        lastLoggedProblem = reason
        let wait = keeper.retryDelay(afterFailures: failures)
        DiagnosticsStore.shared.note(
            "decklink.reconnect",
            detail: "\(request.deviceName): \(reason) — retrying in "
                + "\(Int(wait.rounded()))s (fault \(failures))")
    }

    private var logsThisAttempt: Bool {
        keeper.failures <= 3 || keeper.failures % 30 == 0
    }

    // MARK: Attempts

    private func endAttempt(stopHelperOutput: Bool) {
        attempt += 1
        mirror?.stop()
        mirror = nil
        if stopHelperOutput,
            let proxy = connection?.remoteObjectProxy as? DeckLinkHelperProtocol {
            proxy.stopOutput()
        }
        connection?.invalidate()
        connection = nil
    }

    private func openAttempt() {
        guard let request else { return }
        endAttempt(stopHelperOutput: false)
        let attemptID = attempt
        let deviceName = request.deviceName
        let logging = logsThisAttempt
        if logging, keeper.failures > 0 {
            DiagnosticsStore.shared.note(
                "decklink.start", detail: "\(deviceName): opening again (fault \(keeper.failures))")
        }
        let offered = Locked<TimeInterval?>(nil)
        let accepted = Locked<TimeInterval?>(nil)
        lastOffered = offered
        lastAccepted = accepted

        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        // The helper crashed or was killed. The frames waiting for a reply
        // never get one, so their in-flight slots are gone with them: a new
        // connection, mirror and counter is the only way back to sending.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.attemptLost(attemptID, reason: "the helper quit or crashed")
            }
        }
        // This used to mark the port failed for good. The service not
        // launching is as likely at launch as any other fault, and is
        // retried the same way.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.attemptLost(attemptID, reason: "helper unreachable (connection invalidated)")
            }
        }
        connection.resume()
        self.connection = connection

        let remoteObject = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            // Calls still waiting when the helper goes down fail with
            // "interrupted"; the interruption handler covers those.
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSXPCConnectionInterrupted)
            else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.attemptLost(attemptID, reason: "helper error: \(message)")
            }
        }
        guard let proxy = remoteObject as? DeckLinkHelperProtocol else {
            perform(keeper.lost("helper connection unavailable", at: Self.now))
            return
        }
        proxy.startOutput(
            devicePersistentID: request.devicePersistentID,
            width: Int32(request.width), height: Int32(request.height),
            frameRateNumerator: Int32(request.frameRate * 1000),
            frameRateDenominator: 1000,
            keying: request.keying.rawValue,
            modeID: request.modeID
        ) { @Sendable [weak self] error, wireDetail in
            Task { @MainActor [weak self] in
                self?.openAnswered(attemptID, error: error, wireDetail: wireDetail)
            }
        }
        startMirror(request: request, proxy: proxy, attemptID: attemptID,
                    offered: offered, accepted: accepted, logging: logging)
    }

    private func openAnswered(_ attemptID: Int, error: String?, wireDetail: String) {
        guard attemptID == attempt, let request else { return }
        if let error {
            perform(keeper.openFailed(error, at: Self.now))
            return
        }
        self.wireDetail = wireDetail
        keeper.opened(at: Self.now)
        // Not "sending" yet: that waits for the port to take a frame, so a
        // green dot means pictures are landing, not just that the open
        // answered.
        if logsThisAttempt {
            DiagnosticsStore.shared.note(
                "decklink.start",
                detail: "\(request.deviceName): opened \(wireDetail), waiting for the first frame")
        }
        // The first frame may already have landed (its report raced this one).
        if let landed = lastAccepted.value {
            keeper.frameAccepted(at: landed)
            if keeper.isSending { noteSending() }
        }
        refreshStatus()
    }

    private func attemptLost(_ attemptID: Int, reason: String) {
        guard attemptID == attempt, request != nil else { return }
        perform(keeper.lost(reason, at: Self.now))
    }

    private func firstFrameLanded(_ attemptID: Int) {
        guard attemptID == attempt, request != nil else { return }
        let wasSending = keeper.isSending
        keeper.frameAccepted(at: Self.now)
        if !wasSending, keeper.isSending { noteSending() }
        refreshStatus()
    }

    private func framesRefused(_ attemptID: Int, count: Int) {
        guard attemptID == attempt, request != nil, keeper.isSending else { return }
        perform(keeper.lost("the port refused \(count) frames in a row", at: Self.now))
    }

    // MARK: Frames

    private func startMirror(
        request: Request, proxy: DeckLinkHelperProtocol, attemptID: Int,
        offered: Locked<TimeInterval?>, accepted: Locked<TimeInterval?>, logging: Bool
    ) {
        let deviceName = request.deviceName
        let provider = render.outputs.previewProvider(for: targetID)

        nonisolated(unsafe) let remote = proxy
        let inFlight = Locked(0)
        let refusals = Locked(0)

        let firstOutcomeLogged = Locked(!logging)
        let alphaProbed = Locked(!logging)

        let rampSampleFrame = Locked(0)
        let refusalThreshold = request.frameRate
        let notifyFirstFrame: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.firstFrameLanded(attemptID) }
        }
        let notifyRefused: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.framesRefused(attemptID, count: refusalThreshold) }
        }
        mirror = OutputMirror(
            compositor: render.compositor,
            width: request.width, height: request.height,
            framesPerSecond: request.frameRate,

            transparentBackground: request.keying != .off,
            provider: provider,
            delayFrames: render.outputs.videoDelayProvider(for: targetID),

            adjustments: render.outputs.adjustmentsProvider(for: targetID),
            sourceRect: request.sourceRect,
            placement: request.placement,
            mask: render.outputs.maskProvider(for: targetID),
            composite: request.composite,
            // The card repeats the last frame on its own cadence, so a still
            // frame only goes over XPC twice a second, enough for the
            // delivery check.
            stillResendInterval: 0.5,
            activityLabel: "DeckLink \(deviceName)",
            sink: { pixelBuffer, _ in
                // Counted before the in-flight cap: a helper that stopped
                // answering still has frames offered to it, which is how the
                // check tells a stuck port from an app with nothing to send.
                offered.value = ProcessInfo.processInfo.systemUptime

                let probeNow = alphaProbed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                let sampleIndex = rampSampleFrame.withLock { frame -> Int? in
                    frame += 1
                    switch frame {
                    case 1: return 0
                    case 150: return 1
                    case 300: return 2
                    default: return nil
                    }
                }
                if probeNow || (logging && sampleIndex != nil) {
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                        let midX = CVPixelBufferGetWidth(pixelBuffer) / 2
                        let midY = CVPixelBufferGetHeight(pixelBuffer) / 2
                        let pixels = base.assumingMemoryBound(to: UInt8.self)
                        let corner = pixels[3]
                        let center = midY * bytesPerRow + midX * 4
                        DiagnosticsStore.shared.note(
                            "decklink.alpha",
                            detail: "\(deviceName) t\(sampleIndex.map { $0 * 5 } ?? 0)s "
                                + "corner α=\(corner) center "
                                + "B=\(pixels[center]) G=\(pixels[center + 1]) "
                                + "R=\(pixels[center + 2]) α=\(pixels[center + 3])")
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                }
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
                remote.sendFrame(surface) { @Sendable delivered in
                    inFlight.withLock { $0 -= 1 }

                    let firstOutcome = firstOutcomeLogged.withLock { logged -> Bool in
                        defer { logged = true }
                        return !logged
                    }
                    if firstOutcome {
                        DiagnosticsStore.shared.note(
                            "decklink.frames",
                            detail: "\(deviceName): first frame \(delivered ? "delivered" : "REFUSED")")
                    }
                    let streakHit = refusals.withLock { streak -> Bool in
                        guard !delivered else {
                            streak = 0
                            return false
                        }
                        streak += 1
                        return streak == refusalThreshold
                    }
                    if delivered {
                        let first = accepted.withLock { last -> Bool in
                            defer { last = ProcessInfo.processInfo.systemUptime }
                            return last == nil
                        }
                        if first { notifyFirstFrame() }
                    }
                    if streakHit { notifyRefused() }
                }
            }
        )
        if mirror == nil {
            // No frames will be offered; the keeper's confirm check retries
            // the whole attempt, mirror included.
            DiagnosticsStore.shared.note(
                "decklink.frames", detail: "\(deviceName): mirror init FAILED")
        }
        mirror?.start()
    }
}
