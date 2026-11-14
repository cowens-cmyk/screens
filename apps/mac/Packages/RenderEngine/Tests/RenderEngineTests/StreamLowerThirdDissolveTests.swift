import CoreGraphics
import simd
import Metal
import XCTest
@testable import RenderEngine

/// The livestream's lower third over the camera. One lower third following
/// another dissolves with the old one held up: rendered frame by frame over
/// a transparent background (what the keyer sees), the lower-third band
/// never lets the camera through, the change takes the dissolve's length and
/// ends exactly on the new picture. A lower third arriving over a clear
/// camera, or leaving it clear, keeps the transition it was given.
final class StreamLowerThirdDissolveTests: XCTestCase {
    private let canvas = CGSize(width: 192, height: 108)
    /// Where the pictures' band is: the bottom 40%.
    private let bandTop = 65

    /// Lower-third pictures: transparent above the band, opaque in it. Each
    /// has its own colour so a frame shows which one is up. A picture can be
    /// held back, as one still being read from disk is.
    private final class Pictures: MediaTextureSource, @unchecked Sendable {
        private var textures: [String: MTLTexture] = [:]
        private let lock = NSLock()
        private var held: Set<String> = []

        init?(device: MTLDevice, colors: [String: (UInt8, UInt8, UInt8)], width: Int, height: Int, bandTop: Int) {
            for (id, color) in colors {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                for y in bandTop..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        bytes[i] = color.2
                        bytes[i + 1] = color.1
                        bytes[i + 2] = color.0
                        bytes[i + 3] = 255
                    }
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: width * 4)
                textures[id] = texture
            }
        }

        func hold(_ id: String) { lock.withLock { _ = held.insert(id) } }
        func release(_ id: String) { lock.withLock { _ = held.remove(id) } }
        func ready(_ id: String) -> Bool { lock.withLock { textures[id] != nil && !held.contains(id) } }

        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
            guard ready(mediaID), let texture = lock.withLock({ textures[mediaID] }) else { return nil }
            return .bgra(
                texture: texture,
                transform: VideoColorTransform(
                    ycbcrMatrix: matrix_identity_float3x3, ycbcrOffset: .zero,
                    gamutToWorking: matrix_identity_float3x3, premultipliedAlpha: false),
                retained: [])
        }
    }

    private var compositor: Compositor!
    private var pictures: Pictures!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        compositor = try Compositor(device: device)
        guard let pictures = Pictures(
            device: device, colors: ["lt-a": (255, 0, 0), "lt-b": (0, 0, 255)],
            width: Int(canvas.width), height: Int(canvas.height), bandTop: bandTop)
        else { throw XCTSkip("Could not make the test pictures") }
        self.pictures = pictures
        compositor.mediaSource = pictures
    }

    // MARK: Scenes, as the stream's copy of the live scene has them

    /// A slide's lower-third picture in place of the slide (StreamLowerThirdImage).
    private func picture(_ id: String) -> RenderScene {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(RenderItem(
            id: "stream-lower-third-\(id)", frame: CGRect(origin: .zero, size: canvas),
            content: .media(id: id, scaleMode: .stretch)), to: .slide)
        return scene
    }

    /// A theme's lower-third design: a bar across the band and its words.
    private func design(_ name: String, color: SceneColor) -> RenderScene {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(RenderItem(
            id: "\(name)-bar", frame: CGRect(x: 0, y: CGFloat(bandTop), width: canvas.width, height: canvas.height - CGFloat(bandTop)),
            content: .solid(color)), to: .slide)
        scene.addItem(RenderItem(
            id: "\(name)-words", frame: CGRect(x: 8, y: CGFloat(bandTop) + 6, width: 170, height: 24),
            content: .text(StyledText(string: name, fontSize: 18))), to: .slide)
        return scene
    }

    private var nothing: RenderScene { RenderScene(canvasSize: canvas) }

    // MARK: Reading frames

    private func render(_ scene: RenderScene) throws -> RenderedFrame {
        try compositor.renderFrame(
            scene: scene, width: Int(canvas.width), height: Int(canvas.height), transparentBackground: true)
    }

    private func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> SIMD4<Float> {
        var out = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let halves = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
            out = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        return out
    }

    /// The least key (alpha) anywhere in the band, sampled on a grid.
    private func leastCover(_ frame: RenderedFrame) -> Float {
        var least: Float = 1
        for y in stride(from: bandTop + 1, to: Int(canvas.height) - 1, by: 4) {
            for x in stride(from: 1, to: Int(canvas.width) - 1, by: 6) {
                least = min(least, pixel(frame, x: x, y: y).w)
            }
        }
        return least
    }

    private func engine(showing scene: RenderScene) -> SceneTransitionEngine {
        let pictures = pictures!
        return SceneTransitionEngine(initial: scene, mediaReady: { pictures.ready($0) })
    }

    /// The room's own slide transition, which the stream used to follow.
    private let roomDissolve = SceneTransition(kind: .dissolve, duration: 0.5)
    private let dissolve = 0.2

    /// Frames 1/120 s apart from `start` to `end` seconds after `origin`.
    private func frames(
        _ engine: SceneTransitionEngine, from origin: Date, _ start: Double, _ end: Double
    ) throws -> [(t: Double, frame: RenderedFrame)] {
        try stride(from: start, through: end, by: 1.0 / 120).map { t in
            (t, try render(engine.scene(at: origin.addingTimeInterval(t))))
        }
    }

    // MARK: One lower third to the next

    func testPictureToPictureHoldsTheBandAndLandsOnTheNewPictureIn0_2s() throws {
        let engine = engine(showing: picture("lt-a"))
        engine.push(picture("lt-b"), streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        // Asked before any frame is drawn: drawing past the end retires it.
        let running = engine.transition(on: .slide, at: origin.addingTimeInterval(dissolve - 0.02))
        XCTAssertEqual(running?.kind, .heldDissolve)
        XCTAssertEqual(running?.duration, dissolve)
        XCTAssertNil(engine.transition(on: .slide, at: origin.addingTimeInterval(dissolve + 0.01)), "over in 0.2 s")

        let mid = try render(engine.scene(at: origin.addingTimeInterval(dissolve / 2)))
        XCTAssertGreaterThan(pixel(mid, x: 96, y: 100).z, 0.9, "halfway, the new picture is fully up")
        for (t, frame) in try frames(engine, from: origin, 0, 0.3) {
            XCTAssertGreaterThanOrEqual(leastCover(frame), 0.99, "the camera shows through the band at \(t) s")
        }

        let landed = engine.scene(at: origin.addingTimeInterval(dissolve + 0.01))
        XCTAssertEqual(landed, picture("lt-b"), "it ends exactly on the new picture")
        let end = try render(landed)
        let new = pixel(end, x: 96, y: 100)
        XCTAssertEqual(new.x, 0, accuracy: 0.01)
        XCTAssertEqual(new.z, 1, accuracy: 0.01)
        XCTAssertEqual(pixel(end, x: 96, y: 20).w, 0, accuracy: 0.01, "clear above the band")
    }

    func testDesignToDesignAndDesignToPictureHoldTheBand() throws {
        let pairs: [(RenderScene, RenderScene, String)] = [
            (design("Pastor", color: SceneColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1)),
             design("Point two", color: SceneColor(red: 0.6, green: 0.2, blue: 0.1, alpha: 1)), "design to design"),
            (design("Pastor", color: SceneColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1)), picture("lt-b"), "design to picture"),
            (picture("lt-a"), design("Point two", color: SceneColor(red: 0.6, green: 0.2, blue: 0.1, alpha: 1)), "picture to design"),
        ]
        for (from, to, name) in pairs {
            let engine = engine(showing: from)
            engine.push(to, streamDissolve: dissolve) { _ in self.roomDissolve }
            let origin = Date()
            for (t, frame) in try frames(engine, from: origin, 0, 0.25) {
                XCTAssertGreaterThanOrEqual(leastCover(frame), 0.99, "\(name): the camera shows through at \(t) s")
            }
            XCTAssertEqual(engine.scene(at: origin.addingTimeInterval(dissolve + 0.01)), to, "\(name) lands on the new one")
        }
    }

    func testANewPictureNotReadYetLeavesTheOldOneUpUntilItIs() throws {
        pictures.hold("lt-b")
        let engine = engine(showing: picture("lt-a"))
        engine.push(picture("lt-b"), streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        for (t, frame) in try frames(engine, from: origin, 0, 0.3) {
            XCTAssertGreaterThanOrEqual(leastCover(frame), 0.99, "the old one went before the new one was there, at \(t) s")
            XCTAssertGreaterThan(pixel(frame, x: 96, y: 100).x, 0.99, "the old picture is still fully up at \(t) s")
        }
        pictures.release("lt-b")
        let readyAt = Date()
        _ = engine.scene(at: readyAt)  // a frame notices it is ready
        for (t, frame) in try frames(engine, from: readyAt, 0, 0.25) {
            XCTAssertGreaterThanOrEqual(leastCover(frame), 0.99, "the camera shows through at \(t) s after it was ready")
        }
        XCTAssertEqual(engine.scene(at: readyAt.addingTimeInterval(dissolve + 0.01)), picture("lt-b"))
    }

    func testZeroCuts() {
        let engine = engine(showing: picture("lt-a"))
        engine.push(picture("lt-b"), streamDissolve: 0) { _ in self.roomDissolve }
        XCTAssertNil(engine.transition(on: .slide))
        XCTAssertEqual(engine.scene(at: Date()), picture("lt-b"))
    }

    func testTheSameLowerThirdPublishedAgainDoesNothing() throws {
        let engine = engine(showing: picture("lt-a"))
        engine.push(picture("lt-a"), streamDissolve: dissolve) { _ in self.roomDissolve }
        XCTAssertNil(engine.transition(on: .slide), "no dissolve into itself")
        XCTAssertEqual(engine.scene(at: Date()), picture("lt-a"))
        XCTAssertGreaterThanOrEqual(leastCover(try render(engine.scene(at: Date()))), 0.99)
    }

    // MARK: Words

    /// A lyric line on the livestream: words only, the stream's copy of a
    /// song slide in Lower Third mode.
    private func words(_ id: String, _ text: String, fontSize: Double = 30) -> RenderItem {
        RenderItem(
            id: id, frame: CGRect(x: 10, y: 60, width: 172, height: 44),
            content: .text(StyledText(string: text, fontSize: fontSize)))
    }

    private func opacity(_ id: String, in scene: RenderScene) -> Double {
        scene.layers.first { $0.kind == .slide }?.items.filter { $0.id == id }.map(\.opacity).max() ?? 0
    }

    /// One lyric slide to the next must not have the old line and the new
    /// one both at full strength on top of each other: a plain cross.
    func testWordsToWordsCrossRatherThanHold() throws {
        var from = nothing
        from.addItem(words("verse-1", "Amazing grace"), to: .slide)
        var to = nothing
        to.addItem(words("verse-2", "I once was lost"), to: .slide)
        let engine = engine(showing: from)
        engine.push(to, streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        for t in stride(from: 0.0, through: 0.25, by: 1.0 / 120) {
            let scene = engine.scene(at: origin.addingTimeInterval(t))
            let old = opacity("verse-1::leaving", in: scene), new = opacity("verse-2", in: scene)
            XCTAssertLessThanOrEqual(old + new, 1.001, "both lines up at once at \(t) s")
            XCTAssertFalse(old > 0.52 && new > 0.52, "old \(old) and new \(new) both over half at \(t) s")
        }
        XCTAssertEqual(engine.scene(at: origin.addingTimeInterval(dissolve + 0.01)), to)
    }

    /// A design whose bar stays while its words change: the bar holds the
    /// camera covered, the words cross.
    func testABarWithChangingWordsHoldsTheBarAndCrossesTheWords() throws {
        func design(_ id: String, _ text: String) -> RenderScene {
            var scene = nothing
            scene.addItem(RenderItem(
                id: "bar", frame: CGRect(x: 0, y: CGFloat(bandTop), width: canvas.width, height: canvas.height - CGFloat(bandTop)),
                content: .solid(SceneColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1))), to: .slide)
            scene.addItem(words(id, text), to: .slide)
            return scene
        }
        let engine = engine(showing: design("point-1", "Point one"))
        engine.push(design("point-2", "Point two"), streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        // Frame by frame in time order: drawing past the end retires the
        // change, so the pixels and the items are checked on one pass.
        for t in stride(from: 0.0, through: 0.25, by: 1.0 / 120) {
            let scene = engine.scene(at: origin.addingTimeInterval(t))
            XCTAssertEqual(opacity("bar", in: scene), 1, "the bar stays as it is at \(t) s")
            let old = opacity("point-1::leaving", in: scene), new = opacity("point-2", in: scene)
            XCTAssertLessThanOrEqual(old + new, 1.001, "the words held instead of crossing at \(t) s")
            XCTAssertFalse(old > 0.52 && new > 0.52, "old \(old) and new \(new) both over half at \(t) s")
            XCTAssertGreaterThanOrEqual(leastCover(try render(scene)), 0.99, "the bar let the camera through at \(t) s")
        }
    }

    /// A lyric box whose first line stays and second line changes: the first
    /// line never dips, as rewordedText keeps it for the room.
    func testAnUnchangedLineHoldsWhileTheChangedLineCrosses() throws {
        var from = nothing
        from.addItem(words("lyric-1", "Amazing grace\nhow sweet the sound", fontSize: 16), to: .slide)
        var to = nothing
        to.addItem(words("lyric-2", "Amazing grace\nthat saved a wretch", fontSize: 16), to: .slide)
        let engine = engine(showing: from)
        engine.push(to, streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        let mid = engine.scene(at: origin.addingTimeInterval(dissolve / 2))
        XCTAssertEqual(opacity("lyric-2", in: mid), 1, "the steady line is drawn at full strength")
        XCTAssertGreaterThan(opacity("lyric-2::changed", in: mid), 0, "the new line is crossing in")
        XCTAssertGreaterThan(opacity("lyric-1::leaving", in: mid), 0, "the old line is crossing out")

        // In pixels: the first line's coverage never drops below the
        // settled frame's.
        func firstLine(_ frame: RenderedFrame) -> Float {
            var sum: Float = 0
            for y in 60..<80 { for x in 10..<182 { sum += pixel(frame, x: x, y: y).w } }
            return sum
        }
        let settled = firstLine(try render(to))
        XCTAssertGreaterThan(settled, 1)
        for (t, frame) in try frames(engine, from: origin, 0, 0.25) {
            XCTAssertGreaterThanOrEqual(firstLine(frame), settled * 0.97, "the unchanged line dipped at \(t) s")
        }
    }

    // MARK: Over a clear camera

    func testFromNothingItComesInWithTheTransitionItWasGiven() throws {
        let engine = engine(showing: nothing)
        engine.push(picture("lt-b"), streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        XCTAssertEqual(engine.transition(on: .slide, at: origin)?.kind, .dissolve, "the room's, not the held dissolve")
        let half = try render(engine.scene(at: origin.addingTimeInterval(roomDissolve.duration / 2)))
        XCTAssertEqual(pixel(half, x: 96, y: 100).w, 0.5, accuracy: 0.05, "fading in")
        XCTAssertEqual(engine.scene(at: origin.addingTimeInterval(roomDissolve.duration + 0.01)), picture("lt-b"))

        let cutIn = self.engine(showing: nothing)
        cutIn.push(picture("lt-b"), streamDissolve: dissolve) { _ in nil }
        XCTAssertEqual(cutIn.scene(at: Date()), picture("lt-b"), "and a cut stays a cut")
    }

    func testToNothingItGoesWithTheTransitionItWasGiven() throws {
        let engine = engine(showing: picture("lt-a"))
        engine.push(nothing, streamDissolve: dissolve) { _ in self.roomDissolve }
        let origin = Date()
        XCTAssertEqual(engine.transition(on: .slide, at: origin)?.kind, .dissolve)
        let half = try render(engine.scene(at: origin.addingTimeInterval(roomDissolve.duration / 2)))
        XCTAssertEqual(pixel(half, x: 96, y: 100).w, 0.5, accuracy: 0.05, "fading out")
        let gone = try render(engine.scene(at: origin.addingTimeInterval(roomDissolve.duration + 0.01)))
        XCTAssertEqual(pixel(gone, x: 96, y: 100).w, 0, accuracy: 0.01)
    }

    // MARK: What it was

    /// The stream used to change lower thirds with the room's slide
    /// transition. A plain dissolve has both at half strength halfway, so
    /// the band's key falls to three quarters and the camera shows through.
    func testThePlainDissolveTheStreamUsedLetsTheCameraThrough() throws {
        let engine = engine(showing: picture("lt-a"))
        engine.push(picture("lt-b")) { _ in SceneTransition(kind: .dissolve, duration: 0.2) }
        let mid = try render(engine.scene(at: Date().addingTimeInterval(0.1)))
        XCTAssertLessThan(leastCover(mid), 0.8)
    }
}
