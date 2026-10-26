import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Turns a rendered frame (half-float, linear Display P3, premultiplied) into
/// an 8-bit Display P3 BGRA pixel buffer on the GPU, writing straight into the
/// buffer's IOSurface.
///
/// The feeds used to read every frame back to the CPU and convert it with
/// vImage: unpremultiply, gamma-encode, premultiply. On the show Mac that was
/// most of the time spent on the DeckLink and NDI queues, and reading back a
/// GPU-compressed texture made the driver decompress it on the CPU as well.
/// The same arithmetic in a compute pass costs the GPU a fraction of a
/// millisecond and leaves the CPU nothing to do but hand the buffer on.
final class GPUFrameConverter: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    /// Colors left at full strength rather than multiplied by alpha, for
    /// receivers that read BGRA as straight alpha (an NDI livestream).
    private let straightAlpha: Bool

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // The sRGB curve, which Display P3 shares.
    inline float encodeSRGB(float x) {
        x = clamp(x, 0.0f, 1.0f);
        return x <= 0.0031308f ? 12.92f * x : 1.055f * powr(x, 1.0f / 2.4f) - 0.055f;
    }

    kernel void linearToDisplayP3(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant uint &straightAlpha [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
        float4 pixel = source.read(gid);
        float alpha = clamp(pixel.a, 0.0f, 1.0f);
        float3 color = pixel.a > 0.0f ? pixel.rgb / pixel.a : float3(0.0f);
        color = float3(encodeSRGB(color.r), encodeSRGB(color.g), encodeSRGB(color.b));
        destination.write(straightAlpha != 0 ? float4(color, alpha) : float4(color * alpha, alpha), gid);
    }
    """

    init?(device: MTLDevice, straightAlpha: Bool = false) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "linearToDisplayP3"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess,
              let cache
        else { return nil }
        queue.label = "outputEngine.mirror.gpuConvert"
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
        self.straightAlpha = straightAlpha
    }

    /// Writes `texture` into `pixelBuffer` (32BGRA, IOSurface-backed) and
    /// waits for the GPU. Returns the GPU wall time in milliseconds, or nil
    /// when the buffer could not be wrapped as a texture.
    func convert(texture: MTLTexture, into pixelBuffer: CVPixelBuffer) -> Double? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == texture.width, height == texture.height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        let attributes = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue)
        ] as CFDictionary
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, attributes,
            .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped,
              let destination = CVMetalTextureGetTexture(wrapped),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        let start = CACurrentMediaTime()
        commandBuffer.label = "outputEngine.mirror.gpuConvert"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(destination, index: 1)
        var straight: UInt32 = straightAlpha ? 1 : 0
        encoder.setBytes(&straight, length: MemoryLayout<UInt32>.size, index: 0)
        let group = MTLSize(
            width: pipeline.threadExecutionWidth,
            height: max(1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth),
            depth: 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The wrapper has to outlive the GPU's writes into the surface.
        withExtendedLifetime(wrapped) {}
        guard commandBuffer.status == .completed else { return nil }
        return (CACurrentMediaTime() - start) * 1000
    }
}
