import CoreVideo
import Metal
import XCTest
@testable import RenderEngine

final class CachedTextureTests: XCTestCase {
    private func setUp(_ device: MTLDevice) throws -> (CVMetalTextureCache, CVPixelBuffer) {
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache), kCVReturnSuccess)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer),
            kCVReturnSuccess)
        return try (XCTUnwrap(cache), XCTUnwrap(buffer))
    }

    func testTheTextureKeepsItsCacheAlive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (cache, buffer) = try setUp(device)
        let before = CFGetRetainCount(cache)
        let texture = try XCTUnwrap(CachedTexture(
            cache: cache, pixelBuffer: buffer, format: .bgra8Unorm, width: 64, height: 32))
        XCTAssertGreaterThan(CFGetRetainCount(cache), before)
        XCTAssertEqual(texture.texture.width, 64)
        XCTAssertEqual(texture.texture.height, 32)
    }

    /// The crash: the owner of the cache goes away while a frame made from
    /// it is still on the GPU, and the command buffer's completion lets the
    /// last texture go after the cache.
    func testTheLastTextureCanBeReleasedByTheGPUAfterItsOwnerIsGone() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        var done: [XCTestExpectation] = []
        for _ in 0..<200 {
            let finished = expectation(description: "completed")
            done.append(finished)
            try autoreleasepool {
                let (cache, buffer) = try setUp(device)
                let texture = try XCTUnwrap(CachedTexture(
                    cache: cache, pixelBuffer: buffer, format: .bgra8Unorm, width: 64, height: 32))
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
                blit.fill(buffer: try XCTUnwrap(device.makeBuffer(length: 16)), range: 0..<16, value: 1)
                blit.endEncoding()
                commandBuffer.addCompletedHandler { _ in
                    withExtendedLifetime(texture) {}
                    finished.fulfill()
                }
                commandBuffer.commit()
            }
        }
        wait(for: done, timeout: 10)
    }
}
