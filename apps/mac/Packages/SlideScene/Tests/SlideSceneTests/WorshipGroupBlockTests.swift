import Foundation
import PresenterCore
import RenderEngine
import Testing

@testable import SlideScene

private let at = Date(timeIntervalSince1970: 1_784_800_000)

private func info(nextSlide: Bool) -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "Amazing grace, how sweet the sound", musicKey: "G"),
        next: nextSlide ? .init(body: "I once was lost, but now am found", musicKey: "G") : nil,
        currentGroupName: "Verse 1",
        nextGroupName: nextSlide ? "Chorus" : nil,
        currentGroupColorHex: "#0077CCFF",
        nextGroupColorHex: nextSlide ? "#CC004EFF" : nil,
        currentPresentationName: "Amazing Grace")
}

@Test func theNextGroupResolvesToTheNextSlidesSection() {
    #expect(LinkedText.resolve(TextLink(source: .nextGroup), info: info(nextSlide: true), at: at) == "Chorus")
    #expect(LinkedText.resolve(TextLink(source: .nextGroup), info: info(nextSlide: false), at: at) == nil)
    #expect(!LinkedText.isTimeVarying(TextLink(source: .nextGroup)))
}

@Test func aGroupBlockTakesItsSectionsColour() {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Worship")
    let resolved = LinkedText.resolvedObjects(layout.objects, info: info(nextSlide: true), at: at)
    #expect(resolved.first { $0.groupColorFill == .current }?.fill?.colorHex == "#0077CCFF")
    #expect(resolved.first { $0.groupColorFill == .next }?.fill?.colorHex == "#CC004EFF")
    #expect(resolved.first { $0.name == "Section" }?.text == "Verse 1")
    #expect(resolved.first { $0.name == "Next Section" }?.text == "Chorus")
}

@Test func aSectionWithNoColourKeepsTheBlocksOwnFill() {
    var plain = info(nextSlide: true)
    plain.currentGroupColorHex = nil
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Worship")
    let resolved = LinkedText.resolvedObjects(layout.objects, info: plain, at: at)
    let stored = layout.objects.first { $0.groupColorFill == .current }?.fill
    #expect(resolved.first { $0.groupColorFill == .current }?.fill == stored)
}

@Test func theNextBlockGoesAwayOnTheLastSlide() {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Worship")
    func shown(_ info: ConfidenceInfo) -> [String] {
        let resolved = LinkedText.resolvedObjects(layout.objects, info: info, at: at)
        return resolved.filter { VisibilityRules.isShown($0, among: resolved, info: info, at: at) }.map(\.name)
    }
    #expect(shown(info(nextSlide: true)).contains("Next Section Block"))
    #expect(shown(info(nextSlide: false)).contains("Section Block"))
    #expect(!shown(info(nextSlide: false)).contains("Next Section Block"))
    var noSection = info(nextSlide: true)
    noSection.currentGroupName = nil
    #expect(!shown(noSection).contains("Section Block"), "no section, no block")
}

@Test func theWorshipSectionNamesAreDrawnTurned() {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Worship")
    let scene = ConfidenceSceneBuilder.scene(layout: layout, info: info(nextSlide: true), at: at)
    let items = scene.layers.flatMap(\.items)
    let turned = items.filter { $0.rotationDegrees == -90 }
    #expect(turned.count == 2, "both section names")
    let blocks = items.filter { item in
        if case .shape = item.content { return item.frame.width == 110 } else { return false }
    }
    #expect(blocks.count == 2, "both blocks")
}
