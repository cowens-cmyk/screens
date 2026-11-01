import Foundation
import Testing

@testable import PresenterCore

private func picture(_ name: String, isImage: Bool = true) -> LowerThirdPairing.Item {
    LowerThirdPairing.Item(id: name, name: name, isImage: isImage)
}

@Test func namesPairOnWhatsLeftOnceTheEndingIsOff() {
    #expect(LowerThirdPairing.name("Slide01_Wide") == .init(key: "slide01", isLowerThird: false))
    #expect(LowerThirdPairing.name("Slide01_LowerThird.png") == .init(key: "slide01", isLowerThird: true))
    #expect(LowerThirdPairing.name("slide01 lower third") == .init(key: "slide01", isLowerThird: true))
    #expect(LowerThirdPairing.name("Slide01-LowerThirds") == .init(key: "slide01", isLowerThird: true))
    #expect(LowerThirdPairing.name("Slide01.jpg") == .init(key: "slide01", isLowerThird: false))
    #expect(LowerThirdPairing.name("Worldwide")?.key == "worldwide", "wide only comes off after a separator")
    #expect(LowerThirdPairing.name("_LowerThird") == nil)
}

@Test func fiftyPairsDroppedTogetherMakeFiftySlides() {
    let numbers = (1...50).map { String(format: "%02d", $0) }
    let dropped = numbers.map { picture("Slide\($0)_Wide") } + numbers.reversed().map { picture("Slide\($0)_LowerThird") }
    let plan = LowerThirdPairing.plan(dropped: dropped)
    #expect(plan.slideMedia == numbers.map { "Slide\($0)_Wide" })
    #expect(plan.lowerThirds.count == 50)
    #expect(plan.lowerThirds["Slide07_Wide"] == "Slide07_LowerThird")
    #expect(plan.existingSlides.isEmpty)
}

@Test func aPictureWithoutALowerThirdIsAPlainSlide() {
    let plan = LowerThirdPairing.plan(dropped: [picture("Slide01_Wide"), picture("Slide02_Wide"), picture("Slide01_LowerThird")])
    #expect(plan.slideMedia == ["Slide01_Wide", "Slide02_Wide"])
    #expect(plan.lowerThirds == ["Slide01_Wide": "Slide01_LowerThird"])
}

@Test func aLowerThirdWithNothingToGoOnStaysASlide() {
    let plan = LowerThirdPairing.plan(dropped: [picture("Intro"), picture("Welcome_LowerThird")])
    #expect(plan.slideMedia == ["Intro", "Welcome_LowerThird"])
    #expect(plan.lowerThirds.isEmpty)
}

@Test func lowerThirdsDroppedOnAPresentationGoOnItsSlides() {
    let existing = [(id: "s1", name: "Slide01_Wide"), (id: "s2", name: "Slide02_Wide"), (id: "s3", name: "Lyrics")]
    let plan = LowerThirdPairing.plan(
        dropped: [picture("Slide01_LowerThird"), picture("Slide02_LowerThird"), picture("Slide09_LowerThird")],
        existing: existing)
    #expect(plan.existingSlides == ["s1": "Slide01_LowerThird", "s2": "Slide02_LowerThird"])
    #expect(plan.slideMedia == ["Slide09_LowerThird"])
}

@Test func aDroppedPictureTakesItsLowerThirdBeforeAnOlderSlideDoes() {
    let plan = LowerThirdPairing.plan(
        dropped: [picture("Slide01_Wide"), picture("Slide01_LowerThird")],
        existing: [(id: "old", name: "Slide01_Wide")])
    #expect(plan.lowerThirds == ["Slide01_Wide": "Slide01_LowerThird"])
    #expect(plan.existingSlides.isEmpty)
}

@Test func aVideoCantBeTheLowerThirdButCanHaveOne() {
    let plan = LowerThirdPairing.plan(dropped: [
        picture("Walk_Wide", isImage: false), picture("Walk_LowerThird"),
        picture("Clip_Wide"), picture("Clip_LowerThird", isImage: false),
    ])
    #expect(plan.lowerThirds == ["Walk_Wide": "Walk_LowerThird"])
    #expect(plan.slideMedia == ["Walk_Wide", "Clip_Wide", "Clip_LowerThird"])
}

@Test func droppingOnlyTheWidePicturesBringsTheirLowerThirds() {
    let folder = URL(fileURLWithPath: "/Shows/Sunday", isDirectory: true)
    let listing = ["Slide01_Wide.png", "Slide01_LowerThird.png", "Slide02_Wide.png", "Slide02_LowerThird.png",
                   "Slide03_LowerThird.png", "Slide01_LowerThird.txt", "Notes.png"]
        .map { folder.appendingPathComponent($0) }
    let dropped = [folder.appendingPathComponent("Slide01_Wide.png"), folder.appendingPathComponent("Slide02_Wide.png")]
    let all = LowerThirdPairing.addingPartners(to: dropped) { $0.standardizedFileURL == folder.standardizedFileURL ? listing : [] }
    #expect(all.map(\.lastPathComponent) == ["Slide01_Wide.png", "Slide02_Wide.png", "Slide01_LowerThird.png", "Slide02_LowerThird.png"])
}

@Test func aLowerThirdAlreadyDroppedIsntAddedTwice() {
    let folder = URL(fileURLWithPath: "/Shows/Sunday", isDirectory: true)
    let wide = folder.appendingPathComponent("Slide01_Wide.png")
    let lower = folder.appendingPathComponent("Slide01_LowerThird.png")
    let all = LowerThirdPairing.addingPartners(to: [wide, lower]) { _ in [wide, lower] }
    #expect(all == [wide, lower])
}
