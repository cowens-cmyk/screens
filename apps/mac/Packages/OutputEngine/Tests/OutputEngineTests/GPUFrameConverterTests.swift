import CoreVideo
import Foundation
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class GPUFrameConverterTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        return device
    }

    /// A frame with every case the conversion has to get right: dark values
    /// on the linear toe of the curve, mid greys, out-of-range light, and
    /// partial and zero alpha.
    private func sourceTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var values = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let alpha: Float = [1, 0.5, 0.25, 0][y % 4]
                let r = Float(x) / Float(width - 1)
                let g = Float(x * x) / Float((width - 1) * (width - 1)) * 0.01
                let b = Float(x) / Float(width - 1) * 1.4
                values[i] = Float16(r * alpha)
                values[i + 1] = Float16(g * alpha)
                values[i + 2] = Float16(b * alpha)
                values[i + 3] = Float16(alpha)
            }
        }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)
        for y in 0..<height {
            out.append(contentsOf: UnsafeBufferPointer(start: base + y * rowBytes, count: width * 4))
        }
        return out
    }

    func testGPUConversionMatchesTheVImagePath() throws {
        let device = try device()
        let width = 256, height = 8
        let texture = try sourceTexture(device: device, width: width, height: height)
        let cpu = try XCTUnwrap(PixelBufferConverter(width: width, height: height))
        let gpu = try XCTUnwrap(PixelBufferConverter(width: width, height: height, device: device))
        XCTAssertTrue(cpu.readsBackOnCPU)
        XCTAssertFalse(gpu.readsBackOnCPU)

        let expected = bytes(try XCTUnwrap(cpu.convert(texture: texture)))
        let gpuBuffer = try XCTUnwrap(gpu.convert(texture: texture))
        let actual = bytes(gpuBuffer)
        XCTAssertEqual(expected.count, actual.count)
        var worst = 0
        for index in expected.indices {
            worst = max(worst, abs(Int(expected[index]) - Int(actual[index])))
        }
        XCTAssertLessThanOrEqual(worst, 1, "GPU and vImage agree to within one step")
        XCTAssertEqual(
            CVBufferCopyAttachment(gpuBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_sRGB as String,
            "the GPU path tags its buffers like the CPU path")
    }

    /// The NDI livestream's straight alpha comes out of the GPU the way
    /// vImage made it: full-strength colors beside their alpha.
    func testStraightAlphaMatchesTheVImagePath() throws {
        let device = try device()
        let width = 256, height = 8
        let texture = try sourceTexture(device: device, width: width, height: height)
        let cpu = try XCTUnwrap(PixelBufferConverter(width: width, height: height, straightAlpha: true))
        let gpu = try XCTUnwrap(
            PixelBufferConverter(width: width, height: height, straightAlpha: true, device: device))
        let expected = bytes(try XCTUnwrap(cpu.convert(texture: texture)))
        let actual = bytes(try XCTUnwrap(gpu.convert(texture: texture)))
        var worst = 0
        for index in expected.indices {
            // Where alpha is zero the color carries nothing.
            if expected[index - index % 4 + 3] == 0 { continue }
            worst = max(worst, abs(Int(expected[index]) - Int(actual[index])))
        }
        // vImage divides out alpha after rounding to 8 bits, so at a quarter
        // alpha it lands a step or two from the GPU's exact division.
        XCTAssertLessThanOrEqual(worst, 2)
        // A half-transparent row keeps its red at full strength.
        let rowBytes = width * 4
        let pixel = rowBytes + (width - 1) * 4
        XCTAssertEqual(actual[pixel + 3], 128, accuracy: 1)
        XCTAssertGreaterThan(actual[pixel + 2], 250)
    }

    func testHLGStaysOnTheCPU() throws {
        let device = try device()
        let converter = try XCTUnwrap(
            PixelBufferConverter(width: 8, height: 8, color: .hlg2020, device: device))
        XCTAssertTrue(converter.readsBackOnCPU)
    }

    private func solidScene(_ color: SceneColor) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 160, height: 90))
        scene.addItem(
            RenderItem(id: "fill", frame: CGRect(x: 0, y: 0, width: 160, height: 90), content: .solid(color)),
            to: .stillGraphics)
        return scene
    }

    private func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { usleep(1_000) }
    }

    /// DeckLink repeats its last frame itself: a still feed sends again only
    /// on the interval, and a change goes out on its own tick.
    func testStillFramesAreResentOnlyOnTheInterval() throws {
        let compositor: Compositor
        do { compositor = try Compositor() } catch { throw XCTSkip("no Metal device") }
        let scene = Locked(solidScene(.white))
        let sunk = Locked(0)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 60,
            provider: { scene.value },
            stillResendInterval: 0.5,
            sink: { _, _ in sunk.withLock { $0 += 1 } }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        mirror.tick(at: 0)
        waitFor { sunk.value == 1 }
        for tick in 1..<60 {
            mirror.tick(at: Double(tick) / 60)
        }
        waitFor { sunk.value >= 2 }
        usleep(50_000)
        XCTAssertEqual(sunk.value, 2, "one draw, then one reminder at half a second")

        scene.value = solidScene(.black)
        mirror.tick(at: 1.01)
        waitFor { sunk.value == 3 }
        XCTAssertEqual(sunk.value, 3, "a change is sent on the tick it happens")
    }

    func testACompositeFeedHoldsAStillFrame() throws {
        let compositor: Compositor
        do { compositor = try Compositor() } catch { throw XCTSkip("no Metal device") }
        let scene = solidScene(.white)
        let delivered = Locked<[CVPixelBuffer]>([])
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            composite: [
                .init(provider: { scene }, sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                      placement: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                .init(provider: { scene }, sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                      placement: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ],
            sink: { buffer, _ in delivered.withLock { $0.append(buffer) } }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        for tick in 0..<4 {
            mirror.tick(at: Double(tick) / 30)
            waitFor { delivered.value.count == tick + 1 }
        }
        let buffers = delivered.value
        XCTAssertEqual(buffers.count, 4)
        XCTAssertTrue(buffers.dropFirst().allSatisfy { $0 === buffers[0] }, "drawn once, then resent")
        XCTAssertEqual(mirror.activity.totals().rendered, 1)
    }
}
