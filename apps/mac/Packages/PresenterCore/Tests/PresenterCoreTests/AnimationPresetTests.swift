import Foundation
import Testing
@testable import PresenterCore

struct AnimationPresetTests {
    @Test func recommendedCatalogIsWellFormed() {
        let all = AnimationPreset.recommended
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count, "ids unique")
        for preset in all {
            #expect(preset.id.hasPrefix("builtin."), Comment(rawValue: preset.name))

            #expect(!preset.steps.isEmpty || preset.scroll != nil, Comment(rawValue: preset.name))
            #expect(preset.steps.allSatisfy { $0.ranges == nil && $0.durationSeconds > 0 }, Comment(rawValue: preset.name))
        }
        let names = AnimationPreset.recommendedGroups.map(\.name)
        for expected in ["Settle", "Float", "Slide", "Bar Wipe", "Line Draw", "Pill Grow", "Bracket Pop",
                         "Blur Resolve", "Burn", "Glitch", "Type", "Roll", "Crawl"] {
            #expect(names.contains(expected), Comment(rawValue: expected))
        }
    }

    @Test func applyReplacesAddAppendsAndFollowersStagger() throws {
        let preset = try #require(AnimationPreset.recommended.first { $0.id == "builtin.settle.both" })
        let existing = [AnimationStep(id: "old", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)]
        var counter = 0
        func id() -> String { counter += 1; return "s\(counter)" }

        let leader = AnimationPresetApplication.apply(preset, to: existing, mode: .replace, position: 0, makeID: id)
        #expect(leader.animationSteps?.map(\.id) == ["s1", "s2"], "replace drops the old step; fresh ids")
        #expect(leader.animationSteps?[0].trigger == .onClick && leader.animationSteps?[1].trigger == .onDismiss)
        #expect(leader.animationSteps?[0].delaySeconds == nil)
        #expect(leader.addedIDs == ["s1", "s2"])

        let follower = AnimationPresetApplication.apply(preset, to: existing, mode: .add, position: 2, makeID: id)
        #expect(follower.animationSteps?.map(\.id) == ["old", "s3", "s4"], "add keeps what was there")
        #expect(follower.animationSteps?[1].trigger == .withPrevious, "a follower's lead step rides With Previous")
        #expect(follower.animationSteps?[1].delaySeconds == 0.3, "stagger × position")
        #expect(follower.animationSteps?[2].trigger == .onDismiss)
        #expect(follower.animationSteps?[2].delaySeconds == 0.3, "the Out staggers too")

        let roll = try #require(AnimationPreset.recommended.first { $0.id == "builtin.roll" })
        let rolled = AnimationPresetApplication.apply(roll, to: existing, mode: .replace, position: 0, makeID: id)
        #expect(rolled.animationSteps == nil)
        #expect(rolled.scroll?.axis == .up)
        let crawl = try #require(AnimationPreset.recommended.first { $0.id == "builtin.crawl" })
        #expect(crawl.tilt == 35 && (crawl.scroll?.fadeTowardTop ?? 0) > 0)

        var ranged = existing[0]
        ranged.ranges = [AnimationRange(line: 0, column: 0, length: 3)]
        #expect(AnimationPresetApplication.recipe(from: [ranged])[0].ranges == nil)
    }


    @LibraryActor @Test func animationPresetBoardIsASingletonDocumentKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        #expect(DocumentKind.animationPresetBoard.directoryName == "animation-presets")
        let board = AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: [
            AnimationPreset(id: "u1", name: "Mine", steps: [AnimationStep(id: "x", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)]),
        ])
        try library.store.save(TypedDocument(board))
        let loaded = try library.store.load(AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID)
        #expect(loaded.value.presets.map(\.name) == ["Mine"])
    }
}

extension AnimationPresetTests {

    @LibraryActor @Test func defaultInOutSurviveReopenAndMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        var board = AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: [])
        board.defaultIn = AnimationStep(
            id: "", kind: .in, animation: .wipe, trigger: .onClick, durationSeconds: 0.3
        )
        let document = try TypedDocument(board)
        try library.store.save(document)

        let reopened = try library.store.load(
            AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID
        )
        #expect(reopened.value.defaultIn?.animation == .wipe)
        #expect(reopened.value.defaultIn?.durationSeconds == 0.3)
        #expect(reopened.value.defaultOut == nil, "absent = the app default (Fade · Normal)")

        let replica = try reopened.fork()
        try replica.update {
            $0.defaultOut = AnimationStep(
                id: "", kind: .out, animation: .blur, trigger: .onDismiss, durationSeconds: 0.6
            )
        }
        try reopened.merge(replica)
        #expect(reopened.value.defaultIn?.animation == .wipe)
        #expect(reopened.value.defaultOut?.animation == .blur)
    }
}
