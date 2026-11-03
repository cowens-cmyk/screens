import Foundation
import Testing
@testable import PresenterCore

@LibraryActor @Test func importedCutsFollowTheRoomDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = try Library(rootURL: root)
    var cut = Slide(id: "cut", name: "", objects: [])
    cut.transition = Transition(transitionKind: .cut)
    var dissolve = Slide(id: "dissolve", name: "", objects: [])
    dissolve.transition = Transition(transitionKind: .dissolve, durationSeconds: 1)
    let plain = Slide(id: "plain", name: "", objects: [])
    _ = try library.create(Presentation(
        id: "imported", name: "Imported", presentationKind: .song, themeId: "", slides: [cut, dissolve, plain]))
    _ = try library.create(Presentation(
        id: "fresh", name: "Fresh", presentationKind: .song, themeId: "", slides: [plain]))

    #expect(try library.migrateImportedCutTransitions() == 1)
    let slides = try library.open(Presentation.self, id: "imported").value.slides
    #expect(slides[0].transition == nil)
    #expect(slides[1].transition?.transitionKind == .dissolve)
    #expect(slides[1].transition?.durationSeconds == 1)
    #expect(slides[2].transition == nil)
    #expect(try library.migrateImportedCutTransitions() == 0)
}
