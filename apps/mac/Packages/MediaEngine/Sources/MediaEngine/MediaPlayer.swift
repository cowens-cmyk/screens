import AVFoundation
import CoreVideo
import RenderEngine

final class MediaPlayer: @unchecked Sendable {
    let media: PreparedMedia
    private let player: AVQueuePlayer
    private let factory: SurfaceFactory

    private let windowStart: Double
    private let windowEnd: Double
    private let playRate: Double
    /// Set once at init (the looper is only ever made there), so the
    /// transport can say whether it loops without taking `guarded`.
    private let loops: Bool

    private let needsInitialSeek: Locked<Bool>

    private struct Guarded {
        var looper: AVPlayerLooper?
        var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
        var stats = PlaybackStats()
        var currentSurface: MediaSurface?

        var recentSurfaces: [MediaSurface] = []

        var lastVendedPTS: Double?
    }

    private let guarded: Locked<Guarded>

    /// Serialises frame pulls. Copying a 4K frame out of the decoder and
    /// wrapping it in a texture is held under this, not under `guarded`,
    /// so the main thread's transport and picture checks never wait on it.
    private let pullLock = NSLock()

    /// Hears about failures and stalls; see `PlaybackProblem`.
    private let onProblem: @Sendable (MediaPlayer, PlaybackProblem) -> Void
    private let failureReported = Locked(false)
    private let stopped = Locked(false)
    private let observations = Locked<[NSKeyValueObservation]>([])
    private let notificationTokens = Locked<[any NSObjectProtocol]>([])

    let onFrameVended = Locked<(@Sendable (Double) -> Void)?>(nil)

    /// The sound's fade out as it leaves the screens, applied in the audio
    /// tap so the room and every audio send fade together.
    private let audioFade = Locked<VideoAudioTap.FadeOut?>(nil)

    var stats: PlaybackStats {
        guarded.value.stats
    }

    var transport: MediaTransportState {
        let raw = player.currentTime().seconds
        let windowDuration = windowEnd - windowStart
        let position = raw.isFinite ? min(max(0, raw - windowStart), windowDuration) : 0
        return MediaTransportState(
            duration: windowDuration,
            position: position,
            isPlaying: player.rate != 0,
            isLooping: loops,
            capturedAt: Date(),
            rate: playRate
        )
    }

    init(
        media: PreparedMedia, loop: Bool, factory: SurfaceFactory,
        audioDeviceUID: String? = nil,
        audioSink: Locked<VideoAudioTap.Sink?>? = nil,
        audioDelay: Locked<Double> = Locked(0),
        options: PlaybackOptions = PlaybackOptions(),
        onProblem: @escaping @Sendable (MediaPlayer, PlaybackProblem) -> Void = { _, _ in }
    ) {
        self.media = media
        self.factory = factory
        self.onProblem = onProblem
        self.loops = loop
        let (start, end, rate) = options.resolved(
            duration: media.duration, frameDuration: media.frameDuration
        )
        windowStart = start
        windowEnd = end
        playRate = rate
        player = AVQueuePlayer()
        player.audioOutputDeviceUniqueID = audioDeviceUID
        player.actionAtItemEnd = loop ? .advance : .pause
        let item = AVPlayerItem(asset: media.asset)

        if let audioSink {
            VideoAudioTap.attach(
                to: item, track: media.audioTrack, sink: audioSink, delay: audioDelay, fade: audioFade)
        }
        var state = Guarded()
        if loop {

            state.looper = AVPlayerLooper(
                player: player, templateItem: item,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 60000),
                    end: CMTime(seconds: end, preferredTimescale: 60000)
                )
            )
            needsInitialSeek = Locked(false)
        } else {

            if end < media.duration - media.frameDuration / 2 {
                item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
            }
            player.insert(item, after: nil)
            needsInitialSeek = Locked(start > 0)
        }
        guarded = Locked(state)
        ensureOutputs()
    }

    deinit {
        stopObserving()
    }

    // MARK: Failures and stalls

    /// Watches the player, its items and the looper for the ways AVFoundation
    /// says a video can't play: a failed status, an error mid-play, and a
    /// stall. A looper swaps items as it goes, so the current item is
    /// followed through the player rather than held.
    ///
    /// Started by the engine once the player is under its id, not in init:
    /// a missing file can fail on another thread before init returns, and
    /// a report the engine can't match to an id would be dropped. The
    /// initial values catch whatever already happened.
    func startWatching() {
        let looper = guarded.value.looper
        var kvo: [NSKeyValueObservation] = [
            player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
                guard player.status == .failed else { return }
                self?.fail(player.error, what: "player")
            },
            player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] player, _ in
                guard let item = player.currentItem, item.status == .failed else { return }
                self?.fail(item.error, what: "item")
            },
        ]
        if let looper {
            kvo.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                self?.fail(looper.error, what: "looper")
            })
        }
        observations.value = kvo

        let center = NotificationCenter.default
        let failed = center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, self.owns(item) else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            self.fail(error, what: "play to end")
        }
        let stalled = center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, self.owns(item),
                  !self.stopped.value else { return }
            self.onProblem(self, .stalled)
        }
        notificationTokens.value = [failed, stalled]
    }

    private func owns(_ item: AVPlayerItem) -> Bool {
        if player.currentItem === item { return true }
        return guarded.withLock { $0.outputs[ObjectIdentifier(item)] != nil }
    }

    /// Reports the first failure only: the item, the player and the looper
    /// usually all fail together over one cause.
    private func fail(_ error: (any Error)?, what: String) {
        guard !stopped.value else { return }
        let first = failureReported.withLock { reported in
            defer { reported = true }
            return !reported
        }
        guard first else { return }
        let reason = error.map(MediaEngine.describe) ?? "no error given"
        onProblem(self, .failed("\(what) failed: \(reason)"))
    }

    private func stopObserving() {
        for observation in observations.value { observation.invalidate() }
        observations.value = []
        for token in notificationTokens.value { NotificationCenter.default.removeObserver(token) }
        notificationTokens.value = []
    }

    /// The player's state in a line for the diagnostics log.
    var diagnostics: String {
        let item = player.currentItem
        let status = switch item?.status {
        case .readyToPlay: "ready"
        case .failed: "failed"
        case .unknown: "loading"
        case nil: "no item"
        @unknown default: "?"
        }
        let control = switch player.timeControlStatus {
        case .playing: "playing"
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: "?"
        }
        let time = player.currentTime().seconds
        let frames = stats.framesDisplayed
        let buffered = item.map { $0.isPlaybackBufferEmpty ? "buffer empty" : "buffered" } ?? ""
        return "\(media.summary); \(status), \(control), at \(time.isFinite ? String(format: "%.2f", time) : "?") s, "
            + "\(frames) frames shown, \(buffered)"
    }

    func play() {
        ensureOutputs()
        if needsInitialSeek.withLock({ needed in
            defer { needed = false }
            return needed
        }) {

            seek(to: 0, precise: true) { [weak self] _ in
                self?.applyRate()
            }
        } else {
            applyRate()
        }
    }

    private func applyRate() {
        player.rate = Float(playRate)
    }

    func preroll() async -> Bool {
        ensureOutputs()

        let deadline = Date(timeIntervalSinceNow: 10)
        while player.currentItem?.status != .readyToPlay {
            if Date() > deadline || player.currentItem?.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }

        if needsInitialSeek.withLock({ needed in
            defer { needed = false }
            return needed
        }) {
            await withCheckedContinuation { continuation in
                seek(to: 0, precise: true) { _ in continuation.resume() }
            }
        }
        return await player.preroll(atRate: Float(playRate))
    }

    func setAudioOutputDevice(uid: String?) {
        player.audioOutputDeviceUniqueID = uid
    }

    func setAudioVolume(_ volume: Float) {
        player.volume = volume
    }

    /// Fades the sound to silence over `seconds` from now; a fade already
    /// running carries on. nil brings the sound back.
    func fadeOutAudio(over seconds: Double?) {
        audioFade.withLock { fade in
            guard let seconds else {
                fade = nil
                return
            }
            if fade == nil {
                fade = VideoAudioTap.FadeOut(startHostTime: CACurrentMediaTime(), duration: max(seconds, 0.01))
            }
        }
    }

    var isFadingOutAudio: Bool { audioFade.value != nil }

    /// Whether there's a frame to draw: one already drawn, or one ready.
    /// Asks without taking the frame, so a transition can wait for a
    /// video's first picture before it starts.
    var hasPicture: Bool {
        let item = player.currentItem
        return guarded.withLock { state in
            if state.currentSurface != nil { return true }
            guard let item, item.status == .readyToPlay,
                  let output = state.outputs[ObjectIdentifier(item)] else { return false }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            return time.isValid && output.hasNewPixelBuffer(forItemTime: time)
        }
    }

    func pause() {
        player.pause()
    }

    func resume() {
        ensureOutputs()
        applyRate()
    }

    func seek(to seconds: Double, precise: Bool, completion: (@Sendable (Bool) -> Void)? = nil) {
        let upperBound = max(windowStart, windowEnd - media.frameDuration)
        let target = min(max(windowStart, windowStart + seconds), upperBound)
        guarded.withLock { state in
            state.lastVendedPTS = nil
            state.stats.noteSeek()
        }
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 60000),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [guarded] finished in
            guarded.withLock { state in
                state.lastVendedPTS = nil
                state.stats.noteSeek()
            }
            completion?(finished)
        }
    }

    func stop() {
        stopped.value = true
        stopObserving()
        player.pause()
        guarded.withLock { state in
            state.looper?.disableLooping()
            state.looper = nil
            state.outputs.removeAll()
            state.currentSurface = nil
            state.recentSurfaces.removeAll()
        }
        player.removeAllItems()
    }

    func surface(at hostTime: CFTimeInterval) -> MediaSurface? {

        ensureOutputs()
        guard let item = player.currentItem else {
            return guarded.value.currentSurface
        }
        pullLock.lock()
        defer { pullLock.unlock() }
        // What the pull needs is read under `guarded` and the lock let go
        // before the decoder is asked for a frame.
        let (output, requestTime, current) = guarded.withLock { state -> (AVPlayerItemVideoOutput?, CMTime, MediaSurface?) in
            guard let output = state.outputs[ObjectIdentifier(item)] else {
                return (nil, .invalid, state.currentSurface)
            }
            let itemTime = output.itemTime(forHostTime: hostTime)
            guard itemTime.isValid else { return (nil, .invalid, state.currentSurface) }
            let requestTime = player.rate == 0
                ? itemTime
                : pullTime(itemTime: itemTime, state: state)
            return (output, requestTime, state.currentSurface)
        }
        guard let output else { return current }

        var displayTime = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: requestTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: requestTime, itemTimeForDisplay: &displayTime),
              let surface = factory.makeSurface(from: pixelBuffer)
        else { return current }

        let frameTime = displayTime.isNumeric ? displayTime.seconds : requestTime.seconds
        onFrameVended.value?(frameTime)
        return guarded.withLock { state in
            // Stopped while the frame was copied: keep nothing.
            guard state.outputs[ObjectIdentifier(item)] != nil else { return state.currentSurface }
            state.stats.recordFrame(
                at: frameTime,
                frameDuration: media.frameDuration,
                loopDuration: state.looper != nil ? windowEnd - windowStart : nil
            )
            state.lastVendedPTS = frameTime
            state.currentSurface = surface
            state.recentSurfaces.append(surface)
            if state.recentSurfaces.count > 3 {
                state.recentSurfaces.removeFirst(state.recentSurfaces.count - 3)
            }
            return state.currentSurface
        }
    }

    private func pullTime(itemTime: CMTime, state: Guarded) -> CMTime {
        let frameDuration = media.frameDuration
        guard let last = state.lastVendedPTS, frameDuration > 0 else { return itemTime }
        var expected = last + frameDuration

        if state.looper != nil, expected >= windowEnd - frameDuration / 2 {
            expected = windowStart
        }
        let now = itemTime.seconds

        if expected > now + frameDuration / 4 {
            return itemTime
        }

        if now > expected + 3 * frameDuration {
            return itemTime
        }
        return CMTime(seconds: expected + frameDuration / 4, preferredTimescale: 60000)
    }

    private func ensureOutputs() {
        guarded.withLock { state in
            if let looper = state.looper {
                for item in looper.loopingPlayerItems {
                    attachOutputIfNeeded(to: item, state: &state)
                }
            } else if let item = player.currentItem {
                attachOutputIfNeeded(to: item, state: &state)
            }
        }
    }

    private func attachOutputIfNeeded(to item: AVPlayerItem, state: inout Guarded) {
        guard state.outputs[ObjectIdentifier(item)] == nil else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: media.outputPixelBufferAttributes)
        item.add(output)
        state.outputs[ObjectIdentifier(item)] = output
    }
}
