import Foundation
import Testing

@testable import PresenterCore

/// Presentations may have no slides at all; the arrow keys go straight past
/// them.
@Suite struct PlanSlideStepsTests {
    private func item(_ id: String, _ kind: ServiceItemKind = .presentation) -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: id, refId: "deck-" + id)
    }

    private typealias Place = PlanSlideSteps.Place

    /// Welcome (2 slides), Empty (0), a video, Song (3), Closing (0).
    private var plan: [ServiceItem] {
        [item("welcome"), item("empty"), item("video", .media), item("song"), item("closing")]
    }

    private let counts = ["welcome": 2, "empty": 0, "song": 3, "closing": 0]

    private var places: [Place] {
        PlanSlideSteps.places(plan) { counts[$0.id] }
    }

    @Test func anEmptyPresentationHasNoPlaces() {
        #expect(places == [
            Place(itemID: "welcome", occurrence: 0), Place(itemID: "welcome", occurrence: 1),
            Place(itemID: "song", occurrence: 0), Place(itemID: "song", occurrence: 1), Place(itemID: "song", occurrence: 2),
        ])
        #expect(!places.contains { $0.itemID == "video" }, "media items fire from their own tile")
    }

    @Test func aPresentationStillLoadingHasNoPlacesEither() {
        let loading = PlanSlideSteps.places(plan) { $0.id == "song" ? nil : counts[$0.id] }
        #expect(loading.map(\.itemID) == ["welcome", "welcome"])
    }

    @Test func forwardSkipsTheEmptyPresentation() throws {
        let next = try #require(PlanSlideSteps.step(1, from: Place(itemID: "welcome", occurrence: 1), in: places))
        #expect(places[next] == Place(itemID: "song", occurrence: 0))
    }

    @Test func backSkipsTheEmptyPresentation() throws {
        let previous = try #require(PlanSlideSteps.step(-1, from: Place(itemID: "song", occurrence: 0), in: places))
        #expect(places[previous] == Place(itemID: "welcome", occurrence: 1))
    }

    @Test func theEndsStopWithAnEmptyPresentationLast() {
        #expect(PlanSlideSteps.step(1, from: Place(itemID: "song", occurrence: 2), in: places) == nil,
                "the empty closing deck is not a slide to go to")
        #expect(PlanSlideSteps.step(-1, from: Place(itemID: "welcome", occurrence: 0), in: places) == nil)
    }

    @Test func nothingLiveStartsAtAnEnd() throws {
        #expect(try places[#require(PlanSlideSteps.step(1, from: nil, in: places))] == Place(itemID: "welcome", occurrence: 0))
        #expect(try places[#require(PlanSlideSteps.step(-1, from: nil, in: places))] == Place(itemID: "song", occurrence: 2))
        let firstEmpty = PlanSlideSteps.places([item("empty"), item("song")]) { counts[$0.id] }
        #expect(PlanSlideSteps.step(1, from: nil, in: firstEmpty) == 0, "an empty first item is skipped")
        #expect(firstEmpty.first == Place(itemID: "song", occurrence: 0))
    }

    @Test func aLiveSlideThatIsGoneStartsOver() throws {
        // The live presentation had its slides deleted while one was up.
        let gone = Place(itemID: "empty", occurrence: 0)
        #expect(try places[#require(PlanSlideSteps.step(1, from: gone, in: places))] == Place(itemID: "welcome", occurrence: 0))
    }

    @Test func aPlanOfEmptyPresentationsHasNowhereToGo() {
        let empty = PlanSlideSteps.places([item("empty"), item("closing")]) { counts[$0.id] }
        #expect(empty.isEmpty)
        #expect(PlanSlideSteps.step(1, from: nil, in: empty) == nil)
        #expect(PlanSlideSteps.step(-1, from: nil, in: empty) == nil)
        #expect(PlanSlideSteps.step(0, from: nil, in: places) == nil)
    }

    /// The next item still lists an empty presentation; firing it reports
    /// nothing to fire and ServiceControls walks on to the one after.
    @Test func theNextItemCanBeEmpty() {
        let next = ServiceRunOrder.nextFireable(in: plan, after: "welcome")
        #expect(next?.id == "empty")
        #expect(ServiceRunOrder.nextFireable(in: plan, after: "empty")?.id == "video")
    }

    /// New presentations start with no slides; only songs and scripture
    /// make theirs.
    @Test func newPresentationsStartEmpty() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let app = try String(contentsOf: sources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        let start = try #require(app.range(of: "func createPresentation(named name: String) -> String? {"))
        let body = app[start.upperBound...].prefix(400)
        #expect(body.contains("slides: []"), "Library › New makes an empty presentation")
        #expect(!app.contains("slides: slides.isEmpty ? [Slide("), "no starter slide is slipped in")
    }
}
