import Testing
@testable import PresenterCore

@Test func worshipBackgroundsGoBehindEverythingElseInFront() {
    #expect(MediaLibraryCategory.defaultClassification(forFolder: "Worship Backgrounds") == .background)
    #expect(MediaLibraryCategory.defaultClassification(forFolder: "Worship Backgrounds/Ocean Pack") == .background)
    #expect(MediaLibraryCategory.defaultClassification(forFolder: "worship backgrounds") == .background)
    #expect(MediaLibraryCategory.defaultClassification(forFolder: "Countdowns") == .foreground)
    #expect(MediaLibraryCategory.defaultClassification(forFolder: "Announcements") == .foreground)
    #expect(MediaLibraryCategory.defaultClassification(forFolder: nil) == .foreground)
}
