import Foundation
import CoreVideo
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class OutputMirrorTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        do {
            return try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func solidWhiteScene(canvas: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(
            RenderItem(
                id: "fill",
                frame: CGRect(origin: .zero, size: canvas),
                content: .solid(.white)
            ),
            to: .stillGraphics
        )
        return scene
    }

    func testMirrorDeliversConvertedFrames() throws {
        let compositor = try makeCompositor()
        let expectation = expectation(description: "frames delivered")
        expectation.expectedFulfillmentCount = 3

        let delivered = Locked<[CVPixelBuffer]>([])
        let scene = solidWhiteScene(canvas: CGSize(width: 320, height: 180))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180, framesPerSecond: 30,
            provider: { scene },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count <= 3 { expectation.fulfill() }
            }
        ))

        mirror.start()
        wait(for: [expectation], timeout: 10)
        mirror.stop()

        let buffer = try XCTUnwrap(delivered.value.first)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 180)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let center = base.advanced(by: 90 * rowBytes + 160 * 4)
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(center[0], 250, "blue channel of a white frame")
        XCTAssertGreaterThan(center[1], 250, "green channel of a white frame")
        XCTAssertGreaterThan(center[2], 250, "red channel of a white frame")

        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        XCTAssertEqual(
            primaries as? String,
            kCVImageBufferColorPrimaries_P3_D65 as String,
            "delivered buffers carry their real color tags")
    }

    func testMirrorTicksDirectlyForDeterministicTests() throws {
        let compositor = try makeCompositor()
        let expectation = expectation(description: "one frame")
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            sink: { _, _ in expectation.fulfill() }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(mirror.framesDelivered, 1)
    }

    func testAdjustmentsReachTheFeedAndInvalidateTheStaticResend() throws {

        let compositor = try makeCompositor()
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let adjustments = Locked<OutputAdjustments?>(nil)
        let delivered = Locked<[CVPixelBuffer]>([])
        let firstDelivery = expectation(description: "raw frame")
        let secondDelivery = expectation(description: "corrected frame")
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            adjustments: { adjustments.value },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count == 1 { firstDelivery.fulfill() }
                if count == 2 { secondDelivery.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        func centerLuma(_ buffer: CVPixelBuffer) -> UInt8 {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.advanced(by: 45 * rowBytes + 80 * 4)
                .assumingMemoryBound(to: UInt8.self)
            return pixels[1]  
        }

        mirror.tick(at: 0)
        wait(for: [firstDelivery], timeout: 5)
        XCTAssertGreaterThan(centerLuma(delivered.value[0]), 250, "neutral feed stays white")

        var dark = OutputAdjustments()
        dark.brightness = -1
        adjustments.value = dark

        mirror.tick(at: 0.1)
        wait(for: [secondDelivery], timeout: 5)
        XCTAssertLessThan(
            centerLuma(delivered.value[1]), 10,
            "correction tweak re-renders the static scene on the feed")
    }

    func testSourceRectCarriesTheSlice() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 320, height: 180))
        scene.addItem(
            RenderItem(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: 160, height: 180),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .stillGraphics
        )
        scene.addItem(
            RenderItem(
                id: "right",
                frame: CGRect(x: 160, y: 0, width: 160, height: 180),
                content: .solid(SceneColor(red: 0, green: 0, blue: 1))
            ),
            to: .stillGraphics
        )
        let card = scene
        let delivery = expectation(description: "slice frame")
        let delivered = Locked<CVPixelBuffer?>(nil)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 180, framesPerSecond: 30,
            provider: { card },
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            sink: { buffer, _ in
                let first = delivered.withLock { held -> Bool in
                    guard held == nil else { return false }
                    held = buffer
                    return true
                }
                if first { delivery.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [delivery], timeout: 5)

        let buffer = try XCTUnwrap(delivered.value)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(x: Int, y: Int) -> (b: UInt8, r: UInt8) {
            let pixels = base.advanced(by: y * rowBytes + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return (pixels[0], pixels[2])
        }
        let center = bgra(x: 80, y: 90)
        let nearRight = bgra(x: 156, y: 90)
        XCTAssertGreaterThan(center.r, 200, "the slice is red")
        XCTAssertLessThan(center.b, 60)
        XCTAssertGreaterThan(nearRight.r, 200, "red runs to the slice edge")
        XCTAssertLessThan(nearRight.b, 60, "no blue leak from the neighbor slice")
    }

    func testStaticSceneConvertsOnceThenResends() throws {

        let compositor = try makeCompositor()
        let threeDeliveries = expectation(description: "three deliveries")
        threeDeliveries.expectedFulfillmentCount = 3
        let delivered = Locked<[CVPixelBuffer]>([])
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count <= 3 { threeDeliveries.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        for tick in 0..<3 {
            mirror.tick(at: Double(tick))
            let deadline = Date().addingTimeInterval(5)
            while (mirror.framesDelivered < tick + 1 || delivered.value.count < tick + 1), Date() < deadline {
                usleep(1_000)
            }
            XCTAssertEqual(mirror.framesDelivered, tick + 1)
            XCTAssertEqual(delivered.value.count, tick + 1)
        }
        wait(for: [threeDeliveries], timeout: 5)

        let buffers = delivered.value
        XCTAssertEqual(mirror.framesDelivered, 3, "resends count as delivered — cadence holds")
        guard buffers.count == 3 else { return XCTFail("expected exactly three buffers") }
        XCTAssertTrue(buffers[1] === buffers[0], "second delivery reuses the converted buffer")
        XCTAssertTrue(buffers[2] === buffers[0], "third delivery reuses the converted buffer")
    }

    func testDelayHoldsFramesThenSlidesTheWindow() throws {

        let compositor = try makeCompositor()
        let delay = Locked(2)
        let sunk = Locked(0)
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            delayFrames: { delay.value },
            sink: { _, _ in sunk.withLock { $0 += 1 } }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        func tick(at time: CFTimeInterval, expectSunk: Int) {
            let before = mirror.framesDelivered
            mirror.tick(at: time)
            let deadline = Date().addingTimeInterval(5)
            while (mirror.framesDelivered == before || sunk.value < expectSunk),
                  Date() < deadline { usleep(10_000) }
            XCTAssertEqual(mirror.framesDelivered, before + 1)
            XCTAssertEqual(sunk.value, expectSunk)
        }

        tick(at: 0, expectSunk: 0)  
        tick(at: 1, expectSunk: 0)  
        tick(at: 2, expectSunk: 1)  
        tick(at: 3, expectSunk: 2)  

        delay.value = 0
        tick(at: 4, expectSunk: 3)
        tick(at: 5, expectSunk: 4)
        tick(at: 6, expectSunk: 5)
    }

    func testStoppedMirrorStopsDelivering() throws {
        let unexpected = expectation(description: "stopped mirror must not deliver")
        unexpected.isInverted = true
        let compositor = try makeCompositor()
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let providerCalls = Locked(0)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: {
                providerCalls.withLock { $0 += 1 }
                return scene
            },
            sink: { _, _ in unexpected.fulfill() }
        ))

        mirror.startWithoutTimerForTesting()
        mirror.stop()
        mirror.tick(at: 0)
        XCTAssertEqual(providerCalls.value, 0, "a stopped tick must not request a scene")
        wait(for: [unexpected], timeout: 0.5)
        XCTAssertEqual(mirror.framesDelivered, 0)
        XCTAssertEqual(mirror.framesDropped, 0)
    }

    /// The livestream over NDI, as a receiver lays it over the camera. The
    /// report: a lower third's solid black bar went completely transparent
    /// on the stream and colored bars were see-through at 100% opacity,
    /// because NDI got a frame drawn on black with alpha 255 everywhere and
    /// only a luma key could take the black out.
    func testLivestreamOverNDIKeepsBarsSolidAndTheRestClear() throws {
        let compositor = try makeCompositor()
        let canvas = CGSize(width: 320, height: 180)
        var scene = RenderScene(canvasSize: canvas)
        for item in [
            RenderItem(id: "black-bar", frame: CGRect(x: 0, y: 120, width: 100, height: 60), content: .solid(.black)),
            RenderItem(
                id: "blue-bar", frame: CGRect(x: 110, y: 120, width: 100, height: 60),
                content: .solid(SceneColor(red: 0.1, green: 0.2, blue: 0.8))),
            RenderItem(
                id: "half-white", frame: CGRect(x: 220, y: 120, width: 100, height: 60),
                content: .solid(SceneColor(red: 1, green: 1, blue: 1, alpha: 0.5))),
        ] {
            scene.addItem(item, to: .slide)
        }
        let shown = scene

        let keying = OutputKeying.ndi(livestream: true)
        let frame = expectation(description: "one frame")
        let delivered = Locked<CVPixelBuffer?>(nil)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180, framesPerSecond: 30,
            transparentBackground: keying.transparentBackground,
            straightAlpha: keying.straightAlpha,
            provider: { shown },
            sink: { buffer, _ in
                delivered.value = buffer
                frame.fulfill()
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [frame], timeout: 5)

        let buffer = try XCTUnwrap(delivered.value)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(_ x: Int, _ y: Int) -> [UInt8] {
            let pixel = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
            return [pixel[0], pixel[1], pixel[2], pixel[3]]
        }

        XCTAssertEqual(bgra(160, 40)[3], 0, "nothing drawn: the camera shows through")
        XCTAssertEqual(bgra(50, 150), [0, 0, 0, 255], "a black bar at 100% is solid black")
        let blue = bgra(160, 150)
        XCTAssertEqual(blue[3], 255, "a colored bar at 100% is solid")
        XCTAssertGreaterThan(Int(blue[0]), 180, "and keeps its color: blue")
        XCTAssertLessThan(Int(blue[2]), 80, "with little red")
        let half = bgra(270, 150)
        XCTAssertEqual(Double(half[3]), 128, accuracy: 2, "a half-clear fill stays half clear")
        XCTAssertGreaterThan(half[2], 245, "and white at full strength, as NDI reads it, not grey")
    }

    func testOtherScreensOverNDIStayWholePictures() {
        XCTAssertEqual(OutputKeying.ndi(livestream: false), .fullPicture)
    }
}
