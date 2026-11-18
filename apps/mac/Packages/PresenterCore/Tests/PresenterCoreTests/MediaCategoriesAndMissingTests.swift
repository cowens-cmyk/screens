import Foundation
import Testing
@testable import PresenterCore

// MARK: Church media categories

@Test func hopeStudentsIsThereUntilTheListIsChanged() {
    #expect(MediaCategories.effective(nil) == [MediaCategories.hopeStudents])
    #expect(MediaCategories.hopeStudents.icon == MediaCategoryIcon.studentsLogo)
    #expect(MediaCategories.effective([]) == [], "deleting it keeps it deleted")
}

@Test func aCategoryNameIsAFolderName() {
    #expect(MediaCategories.cleanName("  Kids / Camp: 2026 ") == "Kids - Camp- 2026")
    let list = [MediaCategories.hopeStudents]
    #expect(MediaCategories.problem(with: " ", in: list) == .empty)
    #expect(MediaCategories.problem(with: "videos", in: list) == .builtIn)
    #expect(MediaCategories.problem(with: "Countdowns", in: list) == .builtIn)
    #expect(MediaCategories.problem(with: "All Media", in: list) == .builtIn)
    #expect(MediaCategories.problem(with: "hope students", in: list) == .taken)
    #expect(MediaCategories.problem(with: "hope students", in: list, renaming: "Hope Students") == nil, "its own name")
    #expect(MediaCategories.problem(with: "Kids", in: list) == nil)
}

@Test func addingEditingAndRemovingCategories() {
    var list = MediaCategories.adding(name: "Kids", icon: "star", to: [MediaCategories.hopeStudents])
    #expect(list.map(\.name) == ["Hope Students", "Kids"])
    #expect(MediaCategories.adding(name: "kids", icon: "star", to: list) == list, "no second Kids")
    list = MediaCategories.editing("Kids", name: "Hope Kids", icon: "heart", in: list)
    #expect(list.last == MediaCategoryDefinition(name: "Hope Kids", icon: "heart"))
    list = MediaCategories.removing("hope students", from: list)
    #expect(list.map(\.name) == ["Hope Kids"])
}

@Test func mediaInACategorysFolderIsInIt() {
    let list = [MediaCategories.hopeStudents]
    #expect(MediaCategories.containing(folder: "Hope Students", in: list)?.name == "Hope Students")
    #expect(MediaCategories.containing(folder: "hope students/Camp", in: list)?.name == "Hope Students")
    #expect(MediaCategories.containing(folder: "Videos", in: list) == nil)
    #expect(MediaCategories.containing(folder: nil, in: list) == nil)
    // A built-in folder is never a church category, even if a list says so.
    #expect(MediaCategories.containing(folder: "Videos", in: [MediaCategoryDefinition(name: "Videos", icon: "film")]) == nil)
    #expect(MediaCategories.renamedFolder("Hope Students/Camp", to: "Students") == "Students/Camp")
    #expect(MediaCategories.renamedFolder("Hope Students", to: "Students") == "Students")
}

@Test func everyLogoIconHasAnAsset() {
    #expect(MediaCategoryIcon.logoAsset(MediaCategoryIcon.studentsLogo) == "StudentsLogo")
    #expect(MediaCategoryIcon.logoAsset(MediaCategoryIcon.hopeLogo) == "HopeLogo")
    #expect(MediaCategoryIcon.logoAsset("star") == nil)
    #expect(MediaCategoryIcon.choices.first == MediaCategoryIcon.studentsLogo)
}

// MARK: Missing media in a plan

private func clip(_ id: String, hash: String) -> MediaItem {
    MediaItem(
        id: id, name: "Clip \(id)", mediaKind: .video, classification: .foreground, fileHash: hash,
        fileName: "\(id).mov", fileStatus: .ready, statusDetail: "", tags: [], favorite: false,
        collections: [], loops: false)
}

@Test func aPlansMissingMediaIsFoundInPlanOrder() {
    let media = ["m1": clip("m1", hash: "here"), "m2": clip("m2", hash: "gone"), "m3": clip("m3", hash: "")]
    let audio = ["a1": AudioItem(id: "a1", name: "Song", fileHash: "gone-audio", fileName: "a.m4a", tags: [], favorite: false)]
    let uses = [
        PlanMissingMedia.ItemUse(itemName: "Walk-in", mediaIDs: ["m1", "m2"]),
        PlanMissingMedia.ItemUse(itemName: "Announcements", mediaIDs: ["x9", "m2", "m3", "deck::slide"]),
        PlanMissingMedia.ItemUse(itemName: "Bumper", mediaIDs: [], audioIDs: ["a1", "a2"]),
    ]
    let findings = PlanMissingMedia.findings(
        uses: uses, media: { media[$0] }, audio: { audio[$0] },
        fileExists: { $0 == "here" }, deletedName: { $0 == "x9" ? "Old Promo" : nil })
    #expect(findings.map(\.mediaID) == ["m2", "x9", "m3", "a1", "a2"])
    #expect(findings[0].usedIn == ["Walk-in", "Announcements"])
    #expect(findings[0].problem == .fileMissing)
    #expect(findings[1] == .init(mediaID: "x9", name: "Old Promo", problem: .deleted, usedIn: ["Announcements"]))
    #expect(findings[2].problem == .fileMissing, "an item with no file at all")
    #expect(findings[3].name == "Song")
    #expect(findings[3].isAudio)
    #expect(findings[4].name == "Deleted audio")
    #expect(!findings[0].isAudio)
}

@Test func nothingMissingFindsNothing() {
    let media = ["m1": clip("m1", hash: "here")]
    let findings = PlanMissingMedia.findings(
        uses: [.init(itemName: "Walk-in", mediaIDs: ["m1"])], media: { media[$0] }, audio: { _ in nil },
        fileExists: { _ in true }, deletedName: { _ in nil })
    #expect(findings.isEmpty)
}

@Test func aPlansUsesComeFromItsItems() {
    var service = Service(id: "s", name: "Sunday", serviceDate: "2026-11-22", items: [])
    service.items = [
        ServiceItem(id: "1", itemKind: .header, name: "Pre-service", refId: ""),
        ServiceItem(id: "2", itemKind: .media, name: "Countdown", refId: "m1"),
        ServiceItem(id: "3", itemKind: .presentation, name: "Gone deck", refId: "nope"),
        ServiceItem(id: "4", itemKind: .audio, name: "Walk-in music", refId: "a1"),
        ServiceItem(id: "5", itemKind: .presentation, name: "Welcome", refId: "deck"),
    ]
    #expect(PlanMissingMedia.presentationIDs(in: service) == ["nope", "deck"])
    let uses = PlanMissingMedia.uses(
        of: service, presentationMedia: { $0 == "deck" ? ["m2", "m1"] : nil }, playlist: { _ in nil })
    #expect(uses.map(\.itemName) == ["Countdown", "Walk-in music", "Welcome"])
    #expect(uses[0].mediaIDs == ["m1"])
    #expect(uses[1].audioIDs == ["a1"])
    #expect(uses[2].mediaIDs == ["m1", "m2"])
}

@Test func theStampIgnoresOrder() {
    let a = PlanMissingMedia.Finding(mediaID: "a", name: "A", problem: .fileMissing, usedIn: ["x"])
    let b = PlanMissingMedia.Finding(mediaID: "b", name: "B", problem: .deleted, usedIn: ["y"])
    #expect(PlanMissingMedia.stamp([a, b]) == PlanMissingMedia.stamp([b, a]))
    #expect(PlanMissingMedia.stamp([a]) != PlanMissingMedia.stamp([a, b]))
}
