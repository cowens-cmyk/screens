import Foundation
import Testing

@testable import PresenterCore

private func video(
    folder: String? = nil, loops: Bool = false, endAction: MediaEndAction? = nil, loopOverride: Bool? = nil
) -> MediaItem {
    var item = MediaItem(
        id: "v", name: "Clip", mediaKind: .video, classification: .background,
        fileHash: "h", fileName: "clip.mov", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: loops,
        folder: folder, endAction: endAction)
    item.loopOverride = loopOverride
    return item
}

@Test func categoriesAreFolders() {
    #expect(MediaLibraryCategory.worshipBackgrounds.folder == "Worship Backgrounds")
    #expect(MediaLibraryCategory.countdowns.folder == ServiceCountdown.folder, "the plan's countdown folder")
    #expect(MediaLibraryCategory.audio.folder == nil, "audio is its own library")
    #expect(MediaLibraryCategory.containing(folder: "Worship Backgrounds") == .worshipBackgrounds)
    #expect(MediaLibraryCategory.containing(folder: "Worship Backgrounds/Christmas") == .worshipBackgrounds)
    #expect(MediaLibraryCategory.containing(folder: "worship backgrounds") == .worshipBackgrounds, "made by hand")
    #expect(MediaLibraryCategory.containing(folder: "Countdowns/2026") == .countdowns)
    #expect(MediaLibraryCategory.containing(folder: "Sermon Slides") == .sermonSlides)
    #expect(MediaLibraryCategory.containing(folder: "Needs Sorted") == nil)
    #expect(MediaLibraryCategory.containing(folder: "Backgrounds/Worship Backgrounds") == nil, "only the top folder counts")
    #expect(MediaLibraryCategory.containing(folder: nil) == nil)
    #expect(MediaLibraryCategory.containing(folder: "") == nil)
}

@Test func droppedFilesFindTheirCategory() {
    #expect(MediaLibraryCategory.forImportedFile(URL(fileURLWithPath: "/a/b.mov")) == .videos)
    #expect(MediaLibraryCategory.forImportedFile(URL(fileURLWithPath: "/a/b.mp4")) == .videos)
    #expect(MediaLibraryCategory.forImportedFile(URL(fileURLWithPath: "/a/b.jpg")) == .images)
    #expect(MediaLibraryCategory.forImportedFile(URL(fileURLWithPath: "/a/b.mp3")) == .audio)
    #expect(MediaLibraryCategory.forImportedFile(URL(fileURLWithPath: "/a/b.pdf")) == nil)
}

@Test func onlyWorshipBackgroundsLoopByDefault() {
    #expect(video(folder: "Worship Backgrounds").playsLooping)
    #expect(video(folder: "Worship Backgrounds").endChoice == .loop)
    #expect(video(folder: "Worship Backgrounds").resolvedEndAction == nil, "a looping video never ends")
    for folder in ["Countdowns", "Videos", "Sermon Slides", "Images", "Needs Sorted"] as [String?] + [nil] {
        #expect(!video(folder: folder).playsLooping, "\(folder ?? "no folder") plays once")
        #expect(video(folder: folder).endChoice == .next, "and goes on as a non-looping video always has")
    }
    #expect(video(folder: "Worship Backgrounds").defaultEndChoice == .loop)
    #expect(video(folder: "Videos").defaultEndChoice == .next)
}

@Test func aChoiceBeatsTheCategory() {
    #expect(!video(folder: "Worship Backgrounds", loopOverride: false).playsLooping)
    #expect(video(folder: "Videos", loopOverride: true).playsLooping)
    #expect(video(folder: "Worship Backgrounds", endAction: .hold, loopOverride: false).endChoice == .hold)
}

@Test func olderItemsKeepWhatWasSetByHand() {
    #expect(video(folder: "Videos", loops: true).playsLooping, "marked as looping before there was a choice")
    #expect(!video(folder: "Worship Backgrounds", endAction: .fadeToBlack).playsLooping, "given an ending by hand")
    #expect(video(folder: "Worship Backgrounds").loopChoice == nil, "a plain import follows its category")
}

@Test func choosingRecordsTheOverrideAndKeepsLoopsInStep() {
    var item = video(folder: "Worship Backgrounds")
    item.choose(.hold)
    #expect(item.loopOverride == false && item.loops == false && item.endAction == .hold)
    #expect(item.endChoice == .hold)
    item.choose(.loop)
    #expect(item.loopOverride == true && item.loops == true && item.endAction == nil)
    #expect(item.endChoice == .loop)
    item.choose(nil)
    #expect(item.loopOverride == nil && item.loops == false && item.endAction == nil)
    #expect(item.playsLooping, "back to the category's default")
    for choice in MediaEndChoice.allCases {
        var each = video(folder: "Videos")
        each.choose(choice)
        #expect(each.endChoice == choice)
    }
}

@Test func theLoopsSwitchKeepsTheEnding() {
    var item = video(folder: "Videos", endAction: .fadeToBlack)
    item.setLoops(true)
    #expect(item.playsLooping)
    item.choose(.fadeToBlack)
    item.setLoops(false)
    #expect(!item.playsLooping)
    #expect(item.endAction == .fadeToBlack)
}

@Test func aStillNeverLoops() {
    var still = video(folder: "Worship Backgrounds")
    still.mediaKind = .image
    #expect(!still.playsLooping)
    #expect(still.endChoice == nil)
    #expect(still.loopsWhenPlaced(otherwise: true) == nil)
}

@Test func placingOnASlideLeavesLoopingToTheLibrary() {
    #expect(video(folder: "Worship Backgrounds").loopsWhenPlaced(otherwise: true) == nil)
    #expect(video(folder: "Videos").loopsWhenPlaced(otherwise: true) == nil)
    #expect(video(loopOverride: false).loopsWhenPlaced(otherwise: true) == nil)
    #expect(video(folder: "Needs Sorted").loopsWhenPlaced(otherwise: true) == true, "unfiled: as before")
    let background = CueMedia.droppedOnSlide(for: video(folder: "Worship Backgrounds"))
    #expect(background.loops == nil, "the background follows the library")
    let slide = CueMedia.droppedAsNewSlide(for: video(folder: "Worship Backgrounds"))
    #expect(slide.loops == nil)
}

@Test func theCountdownStillPlaysOnceAndMovesOn() {
    let next = AutoAdvance(delaySeconds: 0, afterPlayback: true)
    #expect(video(folder: "Countdowns").planAdvance(asCountdown: true) == next)
    #expect(video(folder: "Worship Backgrounds").planAdvance(asCountdown: true) == next, "whatever its category")
    #expect(video(folder: "Countdowns", loopOverride: true).planAdvance(asCountdown: true) == next)
}
