import CoreGraphics
import Foundation
import ImageIO
import RenderEngine
import UniformTypeIdentifiers

/// The phone remote's pictures of the audience screen and the next slide:
/// small JPEGs drawn off screen on demand and kept until the scene changes,
/// so a phone asking again (or a second phone) costs nothing.
///
/// Drawing takes the compositor the screens draw with, so a picture waits
/// until the show has been still for a moment and any transition is over:
/// a slide change is exactly when phones ask, and exactly when the screens
/// need every frame. Requests that arrive while one waits share it, and a
/// newer scene takes over a picture not yet drawn. The phone keeps showing
/// the picture it has until then.
///
/// Videos and live inputs draw black. Pulling a frame from a playing video
/// here would take it from the screens' own draw; a still kept for the slide
/// thumbnails stands in where there is one.
@MainActor
final class RemoteFrames {
    static let width = 480
    /// How long the scene must stay the same before it's drawn.
    static let settle: Duration = .milliseconds(600)
    /// The longest a picture waits for the show to be still.
    static let longestWait: Duration = .seconds(4)

    private struct Kept {
        let scene: RenderScene
        let jpeg: Data
    }

    private var kept: [String: Kept] = [:]
    /// The picture each slot will draw next, and when its scene was first asked for.
    private var pending: [String: (scene: RenderScene, since: ContinuousClock.Instant, task: Task<Data?, Never>)] = [:]

    private nonisolated static let queue = DispatchQueue(label: "com.example.mxuslides.remoteFrames", qos: .utility)

    /// `hostTime` is when to look at the scene's animations; the live
    /// screen is drawn a few seconds ahead so a slide caught mid-fade isn't
    /// kept half drawn.
    func jpeg(slot: String, scene: RenderScene, at hostTime: CFTimeInterval = 0, render: RenderContext) async -> Data? {
        if let hit = kept[slot], hit.scene == scene { return hit.jpeg }
        if let waiting = pending[slot], waiting.scene == scene { return await waiting.task.value }

        let since = ContinuousClock.now
        let task = Task { @MainActor [weak self] () -> Data? in
            guard let self else { return nil }
            await self.waitForStill(since: since, transitions: render.transitions)
            // Asked for again with a newer scene while waiting: that one answers.
            if let newer = self.pending[slot], newer.scene != scene { return await newer.task.value }
            let jpeg = await Self.draw(scene, at: hostTime, render: render)
            if self.pending[slot]?.scene == scene { self.pending[slot] = nil }
            if let jpeg { self.kept[slot] = Kept(scene: scene, jpeg: jpeg) }
            return jpeg
        }
        pending[slot] = (scene, since, task)
        return await task.value
    }

    /// Until the scene has stood for `settle` and no transition is running,
    /// or `longestWait` has passed.
    private func waitForStill(since: ContinuousClock.Instant, transitions: SceneTransitionEngine) async {
        let deadline = since + Self.longestWait
        while ContinuousClock.now < deadline {
            var wait = since + Self.settle - ContinuousClock.now
            if let end = transitions.transitionEnd() {
                wait = max(wait, .milliseconds(Int((end.timeIntervalSinceNow * 1000).rounded(.up)) + 100))
            }
            guard wait > .zero else { return }
            try? await Task.sleep(for: min(wait, deadline - ContinuousClock.now))
        }
    }

    private static func draw(_ scene: RenderScene, at hostTime: CFTimeInterval, render: RenderContext) async -> Data? {
        let media = render.media
        let drawn = scene.remappingMediaIDs { id in
            if media.hasStill(id: ThumbnailStore.thumbMediaPrefix + id) { return ThumbnailStore.thumbMediaPrefix + id }
            return media.hasStill(id: id) ? id : "remote.none"
        }
        let compositor = render.compositor
        let width = Self.width
        let height = max(1, Int((CGFloat(width) * scene.canvasSize.height / max(1, scene.canvasSize.width)).rounded()))
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let frame = try? compositor.renderFrame(scene: drawn, width: width, height: height, at: hostTime)
                continuation.resume(returning: frame?.cgImage.flatMap(Self.encode))
            }
        }
    }

    /// Flattened into 8-bit sRGB first: the compositor's frames are wide-gamut
    /// floats, which phones show washed out or not at all.
    private nonisolated static func encode(_ image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
