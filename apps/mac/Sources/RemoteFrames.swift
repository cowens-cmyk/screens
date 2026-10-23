import CoreGraphics
import Foundation
import ImageIO
import RenderEngine
import UniformTypeIdentifiers

/// The phone remote's pictures of the audience screen and the next slide:
/// small JPEGs drawn off screen on demand and kept until the scene changes,
/// so a phone asking again (or a second phone) costs nothing.
///
/// Videos and live inputs draw black. Pulling a frame from a playing video
/// here would take it from the screens' own draw; a still kept for the slide
/// thumbnails stands in where there is one.
@MainActor
final class RemoteFrames {
    static let width = 480

    private struct Kept {
        let scene: RenderScene
        let jpeg: Data
    }

    private var kept: [String: Kept] = [:]
    private var inFlight: [String: (scene: RenderScene, task: Task<Data?, Never>)] = [:]

    private nonisolated static let queue = DispatchQueue(label: "com.example.mxuslides.remoteFrames", qos: .utility)

    /// `hostTime` is when to look at the scene's animations; the live
    /// screen is drawn a few seconds ahead so a slide caught mid-fade isn't
    /// kept half drawn.
    func jpeg(slot: String, scene: RenderScene, at hostTime: CFTimeInterval = 0, render: RenderContext) async -> Data? {
        if let hit = kept[slot], hit.scene == scene { return hit.jpeg }
        if let running = inFlight[slot], running.scene == scene { return await running.task.value }

        let media = render.media
        let drawn = scene.remappingMediaIDs { id in
            if media.hasStill(id: ThumbnailStore.thumbMediaPrefix + id) { return ThumbnailStore.thumbMediaPrefix + id }
            return media.hasStill(id: id) ? id : "remote.none"
        }
        let compositor = render.compositor
        let width = Self.width
        let height = max(1, Int((CGFloat(width) * scene.canvasSize.height / max(1, scene.canvasSize.width)).rounded()))
        let task = Task.detached(priority: .utility) { () -> Data? in
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    let frame = try? compositor.renderFrame(scene: drawn, width: width, height: height, at: hostTime)
                    continuation.resume(returning: frame?.cgImage.flatMap(Self.encode))
                }
            }
        }
        inFlight[slot] = (scene, task)
        let jpeg = await task.value
        if inFlight[slot]?.scene == scene { inFlight[slot] = nil }
        if let jpeg { kept[slot] = Kept(scene: scene, jpeg: jpeg) }
        return jpeg
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
