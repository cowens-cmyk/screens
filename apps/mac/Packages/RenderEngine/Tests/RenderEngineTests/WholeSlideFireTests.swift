import CoreGraphics
import XCTest
@testable import RenderEngine

/// The first slide of a song: new words over a new motion background. On
/// the booth the two went up a moment apart, so the room watched the slide
/// being put together. These fire one such slide into the engine and look
/// at the frames the outputs would draw while the video's first frame is
/// on its way, and after.
final class WholeSlideFireTests: XCTestCase {
    private static let canvas = CGSize(width: 192, height: 108)

    private func slide(words: String, background: String?) -> RenderScene {
        var scene = RenderScene(canvasSize: Self.canvas)
        let frame = CGRect(origin: .zero, size: Self.canvas)
        if let background {
            scene.addItem(
                RenderItem(id: "live-media-loopingVideos", frame: frame, content: .media(id: background)),
                to: .loopingVideos)
        }
        scene.addItem(
            RenderItem(
                id: "\(words)-lyrics", frame: CGRect(x: 20, y: 20, width: 150, height: 60),
                content: .text(StyledText(string: words, fontSize: 24))),
            to: .slide)
        return scene
    }

    /// What a frame shows: the words at full strength on the slide layer,
    /// and the background media at full strength (nil when none is).
    private func look(_ scene: RenderScene) -> (words: [String], background: String?) {
        let words = (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap { item -> String? in
            guard item.opacity > 0.999, case .text(let text) = item.content else { return nil }
            return text.string
        }
        let background = (scene.layers.first { $0.kind == .loopingVideos }?.items ?? [])
            .last { $0.opacity > 0.999 }?.content.mediaID
        return (words, background)
    }

    /// The room's defaults: a slide cuts, media dissolves.
    private func roomDefaults(_ layer: LayerKind) -> SceneTransition? {
        layer == .slide ? nil : SceneTransition(kind: .dissolve, duration: 0.7)
    }

    func testTheWordsWaitForTheirBackgroundAndGoUpWithIt() {
        let ready = Locked<Set<String>>(["song1-bg"])
        let engine = SceneTransitionEngine(initial: slide(words: "Last line of song one", background: "song1-bg")) {
            ready.value.contains($0)
        }
        let fired = Date()
        engine.push(slide(words: "First line of song two", background: "song2-bg"), transitionFor: roomDefaults)

        // Every frame while the video opens: the old slide, whole.
        for ms in stride(from: 0, through: 300, by: 16) {
            let frame = look(engine.scene(at: fired.addingTimeInterval(Double(ms) / 1000)))
            XCTAssertEqual(frame.words, ["Last line of song one"], "at \(ms) ms the new words are not up without their background")
            XCTAssertEqual(frame.background, "song1-bg", "at \(ms) ms")
        }

        // The first frame arrives: words and background change on the same frame.
        ready.value.insert("song2-bg")
        let landed = Date()
        let first = engine.scene(at: landed)
        XCTAssertEqual(look(first).words, ["First line of song two"])
        let incoming = first.layers.first { $0.kind == .loopingVideos }?.items.first { $0.content.mediaID == "song2-bg" }
        XCTAssertNotNil(incoming, "the new background starts on the same frame as the words")
        let done = look(engine.scene(at: landed.addingTimeInterval(0.8)))
        XCTAssertEqual(done.words, ["First line of song two"])
        XCTAssertEqual(done.background, "song2-bg")
    }

    func testACutBackgroundWaitsForItsPictureToo() {
        let ready = Locked<Set<String>>([])
        let engine = SceneTransitionEngine(initial: slide(words: "Welcome", background: nil)) { ready.value.contains($0) }
        let fired = Date()
        engine.push(slide(words: "Verse one", background: "song-bg"), transition: .cut)
        let waiting = look(engine.scene(at: fired.addingTimeInterval(0.1)))
        XCTAssertEqual(waiting.words, ["Welcome"], "no words over an empty background")
        XCTAssertNil(waiting.background)

        ready.value.insert("song-bg")
        let up = look(engine.scene(at: Date()))
        XCTAssertEqual(up.words, ["Verse one"])
        XCTAssertEqual(up.background, "song-bg", "and the two cut in together")
    }

    func testABrokenFileHoldsTheScreensNoLongerThanTheLongestWait() {
        let engine = SceneTransitionEngine(initial: slide(words: "Before", background: "old-bg")) { $0 == "old-bg" }
        let fired = Date()
        engine.push(slide(words: "After", background: "never-opens"), transitionFor: roomDefaults)
        let late = look(engine.scene(at: fired.addingTimeInterval(SceneTransitionEngine.longestMediaWait + 0.05)))
        XCTAssertEqual(late.words, ["After"], "the words go up once the wait runs out")
    }

    func testMediaAlreadyReadyCostsNoWait() {
        let engine = SceneTransitionEngine(initial: slide(words: "One", background: "bg")) { _ in true }
        engine.push(slide(words: "Two", background: "standing-by"), transitionFor: roomDefaults)
        XCTAssertEqual(look(engine.scene(at: Date())).words, ["Two"], "a background with a picture already holds nothing")
    }

    func testTheNextSlideOfTheSameSongIsNotHeld() {
        let engine = SceneTransitionEngine(initial: slide(words: "Line one", background: "bg")) { _ in false }
        engine.push(slide(words: "Line two", background: "bg"), transitionFor: roomDefaults)
        XCTAssertEqual(look(engine.scene(at: Date())).words, ["Line two"], "same background: nothing arrives, nothing waits")
    }

    func testASecondClickInsideTheWaitStillWaitsForTheBackground() {
        let ready = Locked<Set<String>>(["bg1"])
        let engine = SceneTransitionEngine(initial: slide(words: "Old", background: "bg1")) { ready.value.contains($0) }
        let fired = Date()
        engine.push(slide(words: "Song line one", background: "bg2"), transitionFor: roomDefaults)
        engine.push(slide(words: "Song line two", background: "bg2"), transitionFor: roomDefaults)
        let waiting = look(engine.scene(at: fired.addingTimeInterval(0.1)))
        XCTAssertEqual(waiting.words, ["Old"], "line two doesn't go up over the old background either")
        XCTAssertEqual(waiting.background, "bg1")
        ready.value.insert("bg2")
        XCTAssertEqual(look(engine.scene(at: Date())).words, ["Song line two"])
    }
}
