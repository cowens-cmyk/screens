import AVFoundation
import CoreVideo
import Metal
import RenderEngine

public struct PlaybackOptions: Sendable, Equatable {
    public var inPoint: Double?
    public var outPoint: Double?
    public var rate: Double?

    public init(inPoint: Double? = nil, outPoint: Double? = nil, rate: Double? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.rate = rate
    }

    public static let rateRange: ClosedRange<Double> = 0.25 ... 4

    public func resolved(
        duration: Double, frameDuration: Double
    ) -> (start: Double, end: Double, rate: Double) {
        let rate = min(max(self.rate ?? 1, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        var start = min(max(inPoint ?? 0, 0), max(0, duration))
        var end = min(max(outPoint ?? duration, 0), duration)

        if end - start < max(frameDuration, 0.05) {
            start = 0
            end = duration
        }
        return (start, end, rate)
    }

    public func effectiveWallClockDuration(duration: Double, frameDuration: Double) -> Double {
        let (start, end, rate) = resolved(duration: duration, frameDuration: frameDuration)
        return rate > 0 ? (end - start) / rate : end - start
    }
}

public struct PreparedMedia {
    public let url: URL
    public let duration: Double

    public let frameDuration: Double
    public let naturalSize: CGSize
    public let hasAlpha: Bool
    /// The video track's codec as a four-character code ("hvc1", "avc1").
    public let codec: String
    /// Whether this Mac decodes that codec in hardware. A 4K file it has
    /// to decode in software may not keep up.
    public let hardwareDecodes: Bool
    let asset: AVURLAsset
    /// Loaded here, off the main thread, so starting the player doesn't
    /// have to ask the asset for its tracks and wait.
    let audioTrack: AVAssetTrack?
    /// Turns a portrait phone video upright. The video output hands over
    /// frames as they are stored, without the track's rotation; nil when
    /// the track has none.
    var videoComposition: AVVideoComposition? = nil

    var outputPixelBufferAttributes: [String: any Sendable] {
        var attributes: [String: any Sendable] = [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        if hasAlpha {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        } else {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
        }
        return attributes
    }
}

public final class MediaEngine: @unchecked Sendable {
    private let device: MTLDevice
    private let factory: SurfaceFactory
    private let players = Locked<[String: MediaPlayer]>([:])
    private let stills = Locked<[String: StillImage]>([:])

    private let captures = Locked<[String: CaptureSource]>([:])

    private struct LiveSource {
        let latestFrame: @Sendable () -> CVPixelBuffer?
        let onStop: @Sendable () -> Void
    }
    private let liveSources = Locked<[String: LiveSource]>([:])

    private let inputDelay = LiveInputDelay()

    private let generation = Locked<UInt64>(0)

    /// Tells the scene views that an id now shows something else, so one
    /// holding a still frame draws again.
    private func contentChanged() {
        generation.withLock { $0 &+= 1 }
    }
    private let audioDeviceUID = Locked<String?>(nil)
    private let audioVolume = Locked<Float>(1)

    private let videoAudioSink = Locked<VideoAudioTap.Sink?>(nil)

    private let videoAudioDelay = Locked<Double>(0)

    public func setVideoAudioConsumer(
        _ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        videoAudioSink.value = consumer
    }

    public init(device: MTLDevice) throws {
        self.device = device
        factory = try SurfaceFactory(device: device)
    }

    /// Opens a video and checks it can be played here, so a file this Mac
    /// can't decode is refused up front with a reason rather than handed
    /// to a player that never shows a frame.
    public func prepare(url: URL) async throws -> PreparedMedia {
        if let held = standbyVideos.value[url] { return held }
        return try await open(url: url)
    }

    private func open(url: URL) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.noVideoTrack(url)
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (duration, assetPlayable) = try await asset.load(.duration, .isPlayable)
        let (storedSize, minFrameDuration, descriptions) = try await track.load(
            .naturalSize, .minFrameDuration, .formatDescriptions
        )
        let preferredTransform = try await track.load(.preferredTransform)
        let (decodable, trackPlayable) = try await track.load(.isDecodable, .isPlayable)
        let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let codec = Self.fourCC(subtype)
        guard decodable, trackPlayable else {
            throw MediaEngineError.cannotDecode(url, codec: codec)
        }
        guard assetPlayable else { throw MediaEngineError.notPlayable(url) }
        let frameDuration = minFrameDuration.isNumeric && minFrameDuration.seconds > 0
            ? minFrameDuration.seconds
            : 1.0 / 30.0
        let hasAlpha = descriptions.contains(where: Self.carriesAlpha)
        // An iPhone held upright records landscape frames and a 90° turn
        // to show them with. A composition built from the asset applies
        // that turn, as the library's hover preview does. Only a turn or
        // flip gets one; everything else plays as it always has.
        var naturalSize = storedSize
        var composition: AVVideoComposition?
        if Self.turns(preferredTransform), !hasAlpha {
            composition = try? await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            if composition != nil {
                let turned = CGRect(origin: .zero, size: storedSize).applying(preferredTransform)
                naturalSize = CGSize(width: abs(turned.width), height: abs(turned.height))
            }
        }
        return PreparedMedia(
            url: url,
            duration: duration.seconds,
            frameDuration: frameDuration,
            naturalSize: naturalSize,
            hasAlpha: hasAlpha,
            codec: codec,
            hardwareDecodes: PreparedMedia.hardwareDecodes(subtype),
            asset: asset,
            audioTrack: audioTrack,
            videoComposition: composition
        )
    }

    /// Whether a track's transform rotates or flips its frames, rather than
    /// leaving them as they are (or only moving them).
    static func turns(_ transform: CGAffineTransform) -> Bool {
        transform.b != 0 || transform.c != 0 || transform.a < 0 || transform.d < 0
    }

    private static func carriesAlpha(_ description: CMFormatDescription) -> Bool {
        if let contains = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
        ) as? Bool {
            return contains
        }

        let subType = CMFormatDescriptionGetMediaSubType(description)
        return subType == kCMVideoCodecType_AppleProRes4444 || subType == kCMVideoCodecType_AppleProRes4444XQ
    }

    public func play(
        _ media: PreparedMedia, id: String, loop: Bool,
        options: PlaybackOptions = PlaybackOptions()
    ) {
        // One readied ahead for this very file, loop and trim goes up as it
        // is: its decoder is running and its first frame is waiting.
        let key = StandbyPlayerKey(url: media.url, loop: loop, options: options)
        if let ready = standbyPlayers.withLock({ $0.removeValue(forKey: key) }) {
            ready.id.value = id
            ready.player.setAudioOutputDevice(uid: audioDeviceUID.value)
            ready.player.setAudioVolume(audioVolume.value)
            replacePlayer(ready.player, for: id)
            stills.withLock { $0[id] = nil }
            contentChanged()
            ready.player.play()
            return
        }
        let player = makePlayer(media, id: id, loop: loop, options: options)
        replacePlayer(player, for: id)
        player.startWatching()
        stills.withLock { $0[id] = nil }
        contentChanged()
        player.play()
    }

    @discardableResult
    public func preroll(
        _ media: PreparedMedia, id: String, loop: Bool,
        options: PlaybackOptions = PlaybackOptions()
    ) async -> Bool {
        let player = makePlayer(media, id: id, loop: loop, options: options)
        replacePlayer(player, for: id)
        player.startWatching()
        stills.withLock { $0[id] = nil }
        contentChanged()
        return await player.preroll()
    }

    private func makePlayer(
        _ media: PreparedMedia, id: String, loop: Bool, options: PlaybackOptions
    ) -> MediaPlayer {
        let player = MediaPlayer(
            media: media, loop: loop, factory: factory, audioDeviceUID: audioDeviceUID.value,
            audioSink: videoAudioSink, audioDelay: videoAudioDelay, options: options,
            onProblem: { [weak self] player, problem in
                self?.player(player, for: id, reported: problem)
            }
        )
        player.setAudioVolume(audioVolume.value)
        return player
    }

    /// Who hears about a video that fails or stalls, with the id it was
    /// playing under. Called on whatever thread AVFoundation reported on.
    public func setPlaybackProblemHandler(
        _ handler: (@Sendable (_ id: String, _ problem: PlaybackProblem) -> Void)?
    ) {
        problemHandler.value = handler
    }

    private let problemHandler = Locked<(@Sendable (String, PlaybackProblem) -> Void)?>(nil)

    /// A failed player comes off its id at once: left there, the screens
    /// count it as a moving picture that's about to arrive, and its
    /// transport says it's at 0 and paused, so nothing waiting on its end
    /// ever moves on. A report from a player already replaced is old news.
    private func player(_ player: MediaPlayer, for id: String, reported problem: PlaybackProblem) {
        switch problem {
        case .failed:
            let removed = players.withLock { table -> Bool in
                guard table[id] === player else { return false }
                table[id] = nil
                return true
            }
            guard removed else { return }
            // Opened afresh the next time it's asked for, not handed the
            // same asset that just failed.
            let url = player.media.url
            standbyVideos.withLock { $0[url] = nil }
            contentChanged()
            DispatchQueue.global(qos: .utility).async { player.stop() }
        case .stalled:
            guard players.value[id] === player else { return }
        }
        problemHandler.value?(id, problem)
    }

    /// The player's state in a line, for the diagnostics log when a video
    /// hasn't shown a picture: nil when nothing plays under `id`.
    public func playbackDiagnostics(id: String) -> String? {
        players.value[id]?.diagnostics
    }

    public func start(id: String) {
        players.value[id]?.play()
    }

    public func stop(id: String) {
        replacePlayer(nil, for: id)
        stills.withLock { $0[id] = nil }
        contentChanged()
        stopCapture(id: id)
        removeLiveSource(id: id)
    }

    public func stopAll() {
        let stopped = players.withLock { table in
            let all = Array(table.values)
            table.removeAll()
            return all
        }
        for player in stopped { player.stop() }
        stills.withLock { $0.removeAll() }
        contentChanged()
    }

    public func stopAll(withPrefix prefix: String) {
        let stopped = players.withLock { table in
            let matching = table.filter { $0.key.hasPrefix(prefix) }
            for key in matching.keys { table[key] = nil }
            return Array(matching.values)
        }
        for player in stopped { player.stop() }
        stills.withLock { table in
            for key in table.keys where key.hasPrefix(prefix) { table[key] = nil }
        }
        contentChanged()
    }

    /// Whether `id` has a picture to draw yet: a still that's loaded, a
    /// video with its first frame, or a camera or feed that's running.
    public func hasPicture(id: String) -> Bool {
        if captures.value[id] != nil || liveSources.value[id] != nil || stills.value[id] != nil {
            return true
        }
        return players.value[id]?.hasPicture ?? false
    }

    /// Fades out the sound of the videos leaving the screens, each over its
    /// transition, and brings back any other that was fading (a clip
    /// fired again before its fade finished).
    public func setAudioFades(_ fades: [String: Double]) {
        for (id, player) in players.value {
            if let seconds = fades[id] {
                player.fadeOutAudio(over: seconds)
            } else if player.isFadingOutAudio {
                player.fadeOutAudio(over: nil)
            }
        }
    }

    public func hasStill(id: String) -> Bool {
        stills.value[id] != nil
    }

    public var playingIDs: [String] { Array(players.value.keys) }

    public func pause(id: String) {
        players.value[id]?.pause()
    }

    public func resume(id: String) {
        players.value[id]?.resume()
    }

    public func seek(id: String, to seconds: Double, precise: Bool) {
        players.value[id]?.seekByHand(to: seconds, precise: precise)
    }

    public func transport(id: String) -> MediaTransportState? {
        players.value[id]?.transport
    }

    public func transportStates() -> [String: MediaTransportState] {
        players.value.mapValues(\.transport)
    }

    public func setAudioOutputDevice(uid: String?) {
        audioDeviceUID.value = uid
        for player in players.value.values {
            player.setAudioOutputDevice(uid: uid)
        }
        for standby in standbyPlayers.value.values {
            standby.player.setAudioOutputDevice(uid: uid)
        }
    }

    public func setAudioOutputDelay(milliseconds: Int) {
        videoAudioDelay.value = Double(max(0, min(milliseconds, 2000)))
    }

    public func setAudioVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        audioVolume.value = clamped
        for player in players.value.values {
            player.setAudioVolume(clamped)
        }
    }

    private func replacePlayer(_ player: MediaPlayer?, for id: String) {
        let previous = players.withLock { table -> MediaPlayer? in
            let existing = table[id]
            table[id] = player
            return existing
        }
        contentChanged()

        if let previous {
            DispatchQueue.global(qos: .utility).async {
                previous.stop()
            }
        }
    }

    // MARK: Standing by

    /// Pictures decoded and videos opened ahead of time (the day's plan,
    /// as the app opens), by file. `showStill(url:id:)` and `prepare(url:)`
    /// take them from here, so a slide's picture goes up with its words
    /// instead of after the file has been read and decoded.
    private let standbyStills = Locked<[URL: StillImage]>([:])
    private let standbyVideos = Locked<[URL: PreparedMedia]>([:])

    /// Decodes a picture now and keeps it. Returns the memory it takes, in
    /// bytes; 0 when it was already standing by.
    @discardableResult
    public func standBy(still url: URL) throws -> Int {
        guard standbyStills.value[url] == nil else { return 0 }
        let still = try StillImage.load(url: url, device: device)
        standbyStills.withLock { $0[url] = still }
        return Int(still.size.width * still.size.height) * 4
    }

    /// Opens a video now (its tracks read, and checked that this Mac can
    /// play it) and keeps it.
    public func standBy(video url: URL) async throws {
        guard standbyVideos.value[url] == nil else { return }
        let prepared = try await open(url: url)
        standbyVideos.withLock { $0[url] = prepared }
    }

    // MARK: Players standing by

    /// Which player a video needs: the file and how it is to be played.
    private struct StandbyPlayerKey: Hashable {
        var url: URL
        var loop: Bool
        var inPoint: Double?
        var outPoint: Double?
        var rate: Double?

        init(url: URL, loop: Bool, options: PlaybackOptions) {
            self.url = url
            self.loop = loop
            inPoint = options.inPoint
            outPoint = options.outPoint
            rate = options.rate
        }
    }

    private final class StandbyPlayer: @unchecked Sendable {
        let player: MediaPlayer
        /// The id it plays under once it is taken; nil while it waits.
        let id = Locked<String?>(nil)
        init(_ player: MediaPlayer) { self.player = player }
    }

    /// Players made ahead of time for the videos about to be shown, paused
    /// on their first frame. Opening the file is the small part of starting
    /// a video; the wait is the player and its decoder coming up, and this
    /// is done before anyone asks. `play` takes the one that matches.
    private let standbyPlayers = Locked<[StandbyPlayerKey: StandbyPlayer]>([:])

    /// Readies a player for `url`, to be played with this loop and trim.
    /// Returns once it is ready (or couldn't be made).
    public func standBy(playing url: URL, loop: Bool, options: PlaybackOptions = PlaybackOptions()) async {
        let key = StandbyPlayerKey(url: url, loop: loop, options: options)
        guard standbyPlayers.value[key] == nil, let media = try? await prepare(url: url) else { return }
        let holder = Locked<StandbyPlayer?>(nil)
        let player = MediaPlayer(
            media: media, loop: loop, factory: factory, audioDeviceUID: audioDeviceUID.value,
            audioSink: videoAudioSink, audioDelay: videoAudioDelay, options: options,
            onProblem: { [weak self] player, problem in
                // Taken and playing: its id hears about it. Still waiting:
                // one that failed is dropped, so the video starts afresh.
                if let id = holder.value?.id.value {
                    self?.player(player, for: id, reported: problem)
                } else if case .failed = problem {
                    self?.dropStandbyPlayer(key, player)
                }
            }
        )
        let standby = StandbyPlayer(player)
        holder.value = standby
        let added = standbyPlayers.withLock { table -> Bool in
            guard table[key] == nil else { return false }
            table[key] = standby
            return true
        }
        guard added else {
            player.stop()
            return
        }
        player.startWatching()
        if await !player.preroll() { dropStandbyPlayer(key, player) }
    }

    private func dropStandbyPlayer(_ key: StandbyPlayerKey, _ player: MediaPlayer) {
        let removed = standbyPlayers.withLock { table -> Bool in
            guard table[key]?.player === player else { return false }
            table[key] = nil
            return true
        }
        if removed { DispatchQueue.global(qos: .utility).async { player.stop() } }
    }

    /// How many players are standing by.
    public var standbyPlayerCount: Int { standbyPlayers.value.count }

    /// Stops the players standing by for files not in `keep`.
    public func releaseStandbyPlayers(keeping keep: Set<URL>) {
        let dropped = standbyPlayers.withLock { table -> [StandbyPlayer] in
            let gone = table.filter { !keep.contains($0.key.url) }
            for key in gone.keys { table[key] = nil }
            return Array(gone.values)
        }
        guard !dropped.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { dropped.forEach { $0.player.stop() } }
    }

    public func isStandingBy(_ url: URL) -> Bool {
        standbyStills.value[url] != nil || standbyVideos.value[url] != nil
    }

    /// Lets go of what is standing by for files not in `keep`. Anything
    /// already on a screen keeps its own picture.
    public func releaseStandby(keeping keep: Set<URL>) {
        standbyStills.withLock { held in held = held.filter { keep.contains($0.key) } }
        standbyVideos.withLock { held in held = held.filter { keep.contains($0.key) } }
    }

    @discardableResult
    public func showStill(url: URL, id: String) async throws -> CGSize {
        let size: CGSize
        if let existing = stills.value[id], existing.url == url {
            size = existing.size
        } else {
            let still = try standbyStills.value[url] ?? StillImage.load(url: url, device: device)
            stills.withLock { $0[id] = still }
            contentChanged()
            size = still.size
        }
        replacePlayer(nil, for: id)
        return size
    }

    @discardableResult
    public func showStill(image: CGImage, cacheKey: String, id: String) async throws -> CGSize {
        let syntheticURL = URL(string: "still-image://\(cacheKey)")
            ?? URL(fileURLWithPath: "/still-image/\(cacheKey)")
        let size: CGSize
        if let existing = stills.value[id], existing.url == syntheticURL {
            size = existing.size
        } else {
            let still = try StillImage.make(image: image, url: syntheticURL, device: device)
            stills.withLock { $0[id] = still }
            contentChanged()
            size = still.size
        }
        replacePlayer(nil, for: id)
        return size
    }

    public func stats(for id: String) -> PlaybackStats? {
        players.value[id]?.stats
    }

    func playerForTesting(id: String) -> MediaPlayer? {
        players.value[id]
    }

    public var aggregateStats: PlaybackStats {
        players.value.values.reduce(PlaybackStats()) { $0 + $1.stats }
    }
}

extension MediaEngine {

    public static let captureNote = Locked<(@Sendable (String) -> Void)?>(nil)

    public static func captureFrameRates(for device: AVCaptureDevice) -> [Double] {
        let (candidates, active) = CaptureSource.candidates(of: device)
        return CaptureFormatChoice.rates(among: candidates, active: active)
    }

    public func startCapture(device: AVCaptureDevice, id: String, frameRate: Double? = nil) throws {
        let capture = try CaptureSource(device: device, frameRate: frameRate)
        let previous = captures.withLock { table -> CaptureSource? in
            let existing = table[id]
            table[id] = capture
            return existing
        }
        previous?.stop()
        inputDelay.clear(id: id)
        players.withLock { $0[id] = nil }
        stills.withLock { $0[id] = nil }
        contentChanged()
        capture.start()
    }

    public func stopCapture(id: String) {
        let previous = captures.withLock { table -> CaptureSource? in
            let existing = table[id]
            table[id] = nil
            return existing
        }
        previous?.stop()
        inputDelay.clear(id: id)
        contentChanged()
    }

    public func setInputDelay(id: String, frames: Int) {
        inputDelay.setDelay(id: id, frames: frames)
    }

    public var activeCaptureIDs: [String] {
        captures.withLock { Array($0.keys) }
    }

    public func captureFrameAge(id: String, at hostTime: CFTimeInterval) -> Double? {
        captures.value[id]?.frameAge(at: hostTime)
    }

    public func registerLiveSource(
        id: String,
        latestFrame: @escaping @Sendable () -> CVPixelBuffer?,
        onStop: @escaping @Sendable () -> Void
    ) {
        let previous = liveSources.withLock { table -> LiveSource? in
            let existing = table[id]
            table[id] = LiveSource(latestFrame: latestFrame, onStop: onStop)
            return existing
        }
        previous?.onStop()
        inputDelay.clear(id: id)
        players.withLock { $0[id] = nil }
        stills.withLock { $0[id] = nil }
        contentChanged()
    }

    private func removeLiveSource(id: String) {
        let previous = liveSources.withLock { table -> LiveSource? in
            let existing = table[id]
            table[id] = nil
            return existing
        }
        previous?.onStop()
        inputDelay.clear(id: id)
        contentChanged()
    }
}

extension MediaEngine: MediaTextureSource {
    public func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
        if let capture = captures.value[mediaID] {
            guard let frame = capture.latestFrame() else { return nil }
            return factory.makeSurface(from: inputDelay.delayed(frame, id: mediaID))
        }
        if let live = liveSources.value[mediaID] {
            guard let frame = live.latestFrame() else { return nil }
            return factory.makeSurface(from: inputDelay.delayed(frame, id: mediaID))
        }
        if let player = players.value[mediaID] {
            return player.surface(at: hostTime)
        }

        return stills.value[mediaID]?.surface
    }

    public func liveCadence(for mediaID: String) -> LiveCadence? {
        captures.value[mediaID]?.cadence
    }

    /// A camera, a live feed or a video (playing or paused, since a paused
    /// one can be scrubbed) brings frames on its own; a still or an id with
    /// nothing loaded does not, and loading one bumps `contentGeneration`.
    public func motion(for mediaID: String) -> MediaMotion {
        if captures.value[mediaID] != nil || liveSources.value[mediaID] != nil
            || players.value[mediaID] != nil {
            return .moving
        }
        return .still
    }

    public var contentGeneration: UInt64 { generation.value }
}
