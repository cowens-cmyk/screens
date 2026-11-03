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

@LibraryActor @Test func unchangedImportsStayUneditedAfterTheCutMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(rootURL: root)
    var cut = Slide(id: "cut", name: "", objects: [])
    cut.transition = Transition(transitionKind: .cut)
    _ = try library.create(Presentation(
        id: "unedited", name: "Unedited", presentationKind: .song, themeId: "", slides: [cut]))
    _ = try library.create(Presentation(
        id: "edited", name: "Edited", presentationKind: .song, themeId: "", slides: [cut]))
    var ledger = ImportLedger(id: ImportLedger.wellKnownID, entries: [])
    ledger.stamp("unedited", ImportFingerprint.hash(try library.open(Presentation.self, id: "unedited").value)!)
    ledger.stamp("edited", "stale-hash")
    try library.store.save(TypedDocument(ledger))

    #expect(try library.migrateImportedCutTransitions() == 2)
    let stamped = try library.store.load(ImportLedger.self, id: ImportLedger.wellKnownID).value
    #expect(stamped.isUnedited(
        docId: "unedited",
        currentHash: ImportFingerprint.hash(try library.open(Presentation.self, id: "unedited").value)))
    #expect(!stamped.isUnedited(
        docId: "edited",
        currentHash: ImportFingerprint.hash(try library.open(Presentation.self, id: "edited").value)))
}
