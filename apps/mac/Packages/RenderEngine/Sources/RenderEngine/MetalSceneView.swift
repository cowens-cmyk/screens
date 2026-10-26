import AppKit
import Metal
import QuartzCore

@MainActor
public final class MetalSceneView: NSView {

    public var sceneProvider: (@Sendable () -> RenderScene)? {
        get { providerBox.value }
        set { providerBox.value = newValue }
    }

    public var outputAdjustments: OutputAdjustments? {
        get { adjustmentsBox.value }
        set { adjustmentsBox.value = newValue }
    }

    public var outputMask: MTLTexture? {
        get { maskBox.value }
        set { maskBox.value = newValue }
    }

    public var outputSourceRect: CGRect? {
        get { sourceRectBox.value }
        set { sourceRectBox.value = newValue }
    }

    public var outputPlacement: CGRect? {
        get { placementBox.value }
        set { placementBox.value = newValue }
    }

    public struct CompositeSource: @unchecked Sendable {
        public let provider: @Sendable () -> RenderScene
        public let sourceRect: CGRect?
        public let placement: CGRect?
        public let adjustments: OutputAdjustments?
        public let mask: MTLTexture?

        public init(
            provider: @escaping @Sendable () -> RenderScene,
            sourceRect: CGRect?, placement: CGRect?,
            adjustments: OutputAdjustments?, mask: MTLTexture?
        ) {
            self.provider = provider
            self.sourceRect = sourceRect
            self.placement = placement
            self.adjustments = adjustments
            self.mask = mask
        }
    }

    public var compositeSources: [CompositeSource]? {
        get { compositeBox.value }
        set { compositeBox.value = newValue }
    }

    public var videoDelayFrames: Int {
        get { delayBox.value }
        set { delayBox.value = max(0, newValue) }
    }

    public var sceneInset: CGFloat = 0 {
        didSet {
            if sceneInset != oldValue { updateDrawableGeometry() }
        }
    }

    /// Where an editor canvas puts the scene when it is zoomed or panned,
    /// in the view's points, and the pixels per scene unit to draw it at.
    public struct Viewport: Equatable, Sendable {
        public var scale: CGFloat
        public var offset: CGPoint
        /// Pixels per scene unit. Below `scale × backing` the scene is drawn
        /// smaller and magnified; see Compositor.render(…viewScale:).
        public var rasterScale: CGFloat

        public init(scale: CGFloat, offset: CGPoint, rasterScale: CGFloat) {
            self.scale = scale
            self.offset = offset
            self.rasterScale = rasterScale
        }
    }

    /// Asked, with the view's size and backing scale, where the scene goes;
    /// nil letterboxes it inside `sceneInset` as before. Called on the main
    /// thread whenever the view resizes or `refreshViewport()` is called.
    public var viewportResolver: (@MainActor (CGSize, CGFloat) -> Viewport?)? {
        didSet { refreshViewport() }
    }

    /// Picks up a new zoom or pan from `viewportResolver` for the next frame.
    public func refreshViewport() {
        let backing = window?.backingScaleFactor ?? 2
        guard let viewport = viewportResolver?(bounds.size, backing) else {
            viewportBox.value = nil
            return
        }
        viewportBox.value = PixelViewport(
            scale: viewport.scale * backing,
            offset: CGPoint(x: viewport.offset.x * backing, y: viewport.offset.y * backing),
            rasterScale: viewport.rasterScale)
    }

    struct PixelViewport: Equatable {
        var scale: CGFloat
        var offset: CGPoint
        var rasterScale: CGFloat
    }

    public var tickCount: Int { tickState.value.tickCount }
    public var missedTickCount: Int { tickState.value.missedTickCount }

    private struct TickState {
        var tickCount = 0
        var missedTickCount = 0
        var lastTargetTimestamp: CFTimeInterval?
        var shortestTickInterval: CFTimeInterval = .infinity

        mutating func record(targetTimestamp: CFTimeInterval) {
            tickCount += 1
            if let last = lastTargetTimestamp {
                let delta = targetTimestamp - last

                if delta > 0 { shortestTickInterval = min(shortestTickInterval, delta) }
                if delta > shortestTickInterval * 1.75 { missedTickCount += 1 }
            }
            lastTargetTimestamp = targetTimestamp
        }
    }

    private let providerBox = Locked<(@Sendable () -> RenderScene)?>(nil)
    private let tickState = Locked(TickState())
    private let adjustmentsBox = Locked<OutputAdjustments?>(nil)
    private let maskBox = Locked<MTLTexture?>(nil)
    private let sourceRectBox = Locked<CGRect?>(nil)
    private let placementBox = Locked<CGRect?>(nil)
    private let compositeBox = Locked<[CompositeSource]?>(nil)
    private let delayBox = Locked(0)

    private let insetPixelsBox = Locked<CGFloat>(0)
    private let viewportBox = Locked<PixelViewport?>(nil)

    private final class DelayRing {
        var textures: [MTLTexture] = []
        var writeIndex = 0
        var written = 0
    }
    private let delayRingBox = Locked<DelayRing?>(nil)

    private let compositor: Compositor

    private let gateBox = Locked(FrameGate<SceneViewFrameKey>())

    /// This view's line in the performance report: frames drawn and skipped.
    public let activity = FrameActivity.shared.register(kind: "view", label: "Scene view")

    /// Draws the next refresh whatever it shows, for when the layer may have
    /// lost its last frame (a new window or screen).
    public func invalidateFrame() {
        gateBox.withLock { $0.invalidate() }
    }

    private let transparentBackground: Bool
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?

    public init(compositor: Compositor, transparentBackground: Bool = false) {
        self.compositor = compositor
        self.transparentBackground = transparentBackground
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MetalSceneView does not support NSCoder")
    }

    public override func makeBackingLayer() -> CALayer {
        metalLayer.device = compositor.device
        metalLayer.pixelFormat = Compositor.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: Compositor.workingColorSpaceName)
        metalLayer.framebufferOnly = false 
        metalLayer.isOpaque = !transparentBackground
        metalLayer.backgroundColor = transparentBackground
            ? CGColor(gray: 0, alpha: 0)
            : CGColor(gray: 0, alpha: 1)
        return metalLayer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        updateDrawableGeometry()
        invalidateFrame()
        startDisplayLink()
    }

    public override func layout() {
        super.layout()
        updateDrawableGeometry()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableGeometry()
        invalidateFrame()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {

        updateDrawableGeometry()
        invalidateFrame()
    }

    private func updateDrawableGeometry() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        insetPixelsBox.value = sceneInset * scale
        refreshViewport()
        updateFrameRatePacing()
    }

    /// A ceiling for previews: an output runs at its screen's full rate, but
    /// a small monitor in the window needs no more than 30 to look live, and
    /// at 120 several of them kept the app busy doing nothing.
    public var maximumFramesPerSecond: Float? {
        didSet { if maximumFramesPerSecond != oldValue { updateFrameRatePacing() } }
    }

    private func updateFrameRatePacing() {
        guard let displayLink else { return }
        let screenFPS = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        let maxFPS = min(screenFPS, maximumFramesPerSecond ?? screenFPS)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, maxFPS),
            maximum: maxFPS,
            preferred: maxFPS
        )
    }

    /// Stops drawing while the preview is out of sight (a folded panel keeps
    /// its previews built but hidden). The last frame stays in the layer.
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue, let link = displayLink else { return }
            let paused = isPaused
            nonisolated(unsafe) let movingLink = link
            RenderThread.shared.perform { movingLink.isPaused = paused }
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.isPaused = isPaused
        displayLink = link
        updateFrameRatePacing()

        nonisolated(unsafe) let movingLink = link
        RenderThread.shared.perform {
            movingLink.add(to: RunLoop.current, forMode: .common)
        }
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        displayLink = nil

        nonisolated(unsafe) let movingLink = link
        RenderThread.shared.perform {
            movingLink.invalidate()
        }
    }
}

/// Everything besides time that sets what a scene view draws. Two equal
/// keys draw the same picture, so the second can be skipped.
struct SceneViewFrameKey: Equatable {
    var scenes: [RenderScene]
    var sourceRects: [CGRect?]
    var placements: [CGRect?]
    var adjustments: [OutputAdjustments?]
    var masks: [ObjectIdentifier?]
    var inset: CGFloat
    var delay: Int
    var width: Int
    var height: Int
    var mediaGeneration: UInt64
    /// An editor canvas's zoom and pan: a pinch redraws though the scene
    /// stays the same.
    var viewport: MetalSceneView.PixelViewport? = nil
}

extension MetalSceneView: CAMetalDisplayLinkDelegate {
    public nonisolated func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {

        let targetTimestamp = update.targetTimestamp
        tickState.withLock { $0.record(targetTimestamp: targetTimestamp) }
        let target = update.drawable.texture
        let media = compositor.mediaSource
        let generation = media?.contentGeneration ?? 0

        // The scenes are read once per refresh, whether or not the frame is
        // drawn: comparing them with the last drawn ones is how a change is
        // seen on the very refresh it happens.
        if let sources = compositeBox.value, !sources.isEmpty {
            let scenes = sources.map { $0.provider() }
            let key = SceneViewFrameKey(
                scenes: scenes, sourceRects: sources.map(\.sourceRect),
                placements: sources.map(\.placement), adjustments: sources.map(\.adjustments),
                masks: sources.map { $0.mask.map(ObjectIdentifier.init) },
                inset: 0, delay: 0, width: target.width, height: target.height,
                mediaGeneration: generation)
            guard shouldRender(key: key, scenes: scenes, delay: 0, at: targetTimestamp, media: media)
            else { return }
            compositor.render(
                composite: zip(sources, scenes).map { source, scene in
                    Compositor.OutputCompositeLayer(
                        scene: scene,
                        sourceRect: source.sourceRect,
                        placement: source.placement,
                        adjustments: source.adjustments,
                        mask: source.mask
                    )
                },
                into: update.drawable, at: targetTimestamp
            )
            return
        }
        guard let provider = providerBox.value else { return }
        let scene = provider()
        let delay = delayBox.value
        let adjustments = adjustmentsBox.value
        let sourceRect = sourceRectBox.value
        let placement = placementBox.value
        let mask = maskBox.value
        let inset = insetPixelsBox.value
        let viewport = delay == 0 ? viewportBox.value : nil
        let key = SceneViewFrameKey(
            scenes: [scene], sourceRects: [sourceRect], placements: [placement],
            adjustments: [adjustments], masks: [mask.map(ObjectIdentifier.init)],
            inset: inset, delay: delay, width: target.width, height: target.height,
            mediaGeneration: generation, viewport: viewport)
        guard shouldRender(key: key, scenes: [scene], delay: delay, at: targetTimestamp, media: media)
        else { return }
        if let viewport {
            delayRingBox.value = nil
            compositor.render(
                scene: scene, into: update.drawable, at: targetTimestamp,
                transparentBackground: transparentBackground,
                viewScale: viewport.scale, viewOffset: viewport.offset,
                rasterScale: viewport.rasterScale
            )
            return
        }
        guard delay > 0 else {
            delayRingBox.value = nil
            compositor.render(
                scene: scene, into: update.drawable, at: targetTimestamp,
                transparentBackground: transparentBackground,
                adjustments: adjustments, sourceRect: sourceRect,
                placement: placement, mask: mask,
                inset: inset
            )
            return
        }

        let ring: DelayRing? = delayRingBox.withLock { box in
            let wanted = delay + 1
            if let existing = box, existing.textures.count == wanted,
               existing.textures.first?.width == target.width,
               existing.textures.first?.height == target.height {
                return existing
            }
            let fresh = DelayRing()
            for index in 0 ..< wanted {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: Compositor.pixelFormat,
                    width: target.width, height: target.height, mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let texture = compositor.device.makeTexture(descriptor: descriptor)
                else { return nil }
                texture.label = "sceneView.delay\(index)"
                fresh.textures.append(texture)
            }
            box = fresh
            return fresh
        }
        guard let ring else {
            compositor.render(
                scene: scene, into: update.drawable, at: targetTimestamp,
                transparentBackground: transparentBackground,
                adjustments: adjustments, sourceRect: sourceRect,
                placement: placement, mask: mask
            )
            return
        }
        let write = ring.writeIndex
        compositor.render(
            scene: scene, into: ring.textures[write], at: targetTimestamp,
            adjustments: adjustments, sourceRect: sourceRect,
            placement: placement, mask: mask
        )
        ring.written += 1
        ring.writeIndex = (write + 1) % ring.textures.count
        let read = ring.written > delay ? ring.writeIndex : write
        compositor.present(texture: ring.textures[read], into: update.drawable)
    }

    /// Asks the gate whether this refresh draws, and counts the answer. A
    /// skipped refresh leaves the drawable unpresented, so the layer keeps
    /// showing the last frame.
    private nonisolated func shouldRender(
        key: SceneViewFrameKey, scenes: [RenderScene], delay: Int,
        at now: CFTimeInterval, media: MediaTextureSource?
    ) -> Bool {
        let motion = SceneMotion.of(scenes, at: now, media: media)
        let decision = gateBox.withLock { gate in
            // A delayed output keeps drawing until the change has come out
            // the far end of its queue.
            gate.trailingFrames = delay
            return gate.decide(key: key, motion: motion, now: now)
        }
        activity.record(rendered: decision.renders, at: now)
        return decision.renders
    }
}
