import CoreVideo
import Metal

/// A texture made from a pixel buffer by a CVMetalTextureCache, holding the
/// cache too. A CVMetalTexture calls back into its cache when it's freed but
/// doesn't keep the cache alive, so the last texture released after the
/// cache (by a command buffer's completion, on Metal's completion queue)
/// wrote into a cache already being torn down: a DeckLink output that closed
/// or reconnected while its last frame was on the GPU crashed the app. This
/// lets the texture go first and the cache after it, on the same thread.
public final class CachedTexture: @unchecked Sendable {
    public let texture: MTLTexture
    private var wrapper: CVMetalTexture?
    private let cache: CVMetalTextureCache

    /// Plane `plane` of `pixelBuffer` as a `format` texture of `width` ×
    /// `height`, or nil when the cache can't wrap it.
    public init?(
        cache: CVMetalTextureCache, pixelBuffer: CVPixelBuffer, attributes: CFDictionary? = nil,
        format: MTLPixelFormat, width: Int, height: Int, plane: Int = 0
    ) {
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, attributes,
            format, width, height, plane, &wrapped) == kCVReturnSuccess,
              let wrapped,
              let texture = CVMetalTextureGetTexture(wrapped)
        else { return nil }
        self.texture = texture
        self.wrapper = wrapped
        self.cache = cache
    }

    deinit {
        // Stored properties are released in no promised order; the wrapper
        // must be gone while the cache is still alive.
        wrapper = nil
    }
}
