import CoreGraphics
import Foundation
import Metal
import Observation
import QuartzCore
import RenderEngine

@MainActor
@Observable
public final class PlaceholderScreen: Identifiable {
    public let id: UUID
    public let name: String
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int

    public nonisolated(unsafe) let texture: MTLTexture

    public private(set) var isRunning = false
    public var framesRendered: Int { frameCounter.value }

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

    private let compositor: Compositor
    private let adjustmentsBox = Locked<OutputAdjustments?>(nil)
    private let maskBox = Locked<MTLTexture?>(nil)
    private let providerBox = Locked<(@Sendable () -> RenderScene)?>(nil)
    private let frameCounter = Locked(0)
    private struct FrameKey: Equatable {
        var scene: RenderScene
        var adjustments: OutputAdjustments?
        var mask: ObjectIdentifier?
        var mediaGeneration: UInt64
    }

    /// The texture keeps its last frame for as long as nothing changes, so
    /// unlike a window's layer it needs no safety redraw.
    private let gate = Locked(FrameGate<FrameKey>(refreshInterval: .infinity))

    private nonisolated let activity: FrameActivity.Handle
    @ObservationIgnored private var timer: Timer?

    public init?(
        compositor: Compositor,
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        framesPerSecond: Int = 30
    ) {
        guard width > 0, height > 0, framesPerSecond > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )

        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = compositor.device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "placeholderScreen.\(name)"
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.texture = texture
        self.compositor = compositor
        activity = FrameActivity.shared.register(kind: "screen", label: "Screen \u{201C}\(name)\u{201D}")
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = Timer(timeInterval: 1.0 / Double(framesPerSecond), repeats: true) {
            [weak self] _ in

            self?.renderNow(at: CACurrentMediaTime())
        }
        self.timer = timer
        nonisolated(unsafe) let movingTimer = timer
        RenderThread.shared.perform {
            RunLoop.current.add(movingTimer, forMode: .common)
        }
    }

    public func stop() {
        guard let timer else { return }
        self.timer = nil
        isRunning = false

        nonisolated(unsafe) let movingTimer = timer
        RenderThread.shared.perform {
            movingTimer.invalidate()
        }
    }

    public nonisolated func renderNow(at hostTime: CFTimeInterval) {
        guard let provider = providerBox.value else { return }
        let scene = provider()

        let adjustments = adjustmentsBox.value
        let mask = maskBox.value
        let media = compositor.mediaSource
        let key = FrameKey(
            scene: scene, adjustments: adjustments, mask: mask.map(ObjectIdentifier.init),
            mediaGeneration: media?.contentGeneration ?? 0)
        let motion = SceneMotion.of(scene, at: hostTime, media: media)
        let decision = gate.withLock { $0.decide(key: key, motion: motion, now: hostTime) }
        activity.record(rendered: decision.renders, at: CACurrentMediaTime())
        guard decision.renders else {
            RenderPulse.shared.placeholderSkip()
            return
        }
        let encodeStart = CACurrentMediaTime()
        compositor.render(
            scene: scene, into: texture, at: hostTime, adjustments: adjustments, mask: mask)
        RenderPulse.shared.placeholderFrame(
            encodeMS: (CACurrentMediaTime() - encodeStart) * 1000)
        frameCounter.withLock { $0 += 1 }
    }
}
