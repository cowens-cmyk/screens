import Foundation
import Testing
@testable import PresenterCore

@Test func theAnnouncementsLayoutHasItsTimerTheClockAndTheRoom() {
    let layout = ConfidenceLayoutTemplate.announcements.make(name: "Announcements")
    #expect(AnnouncementsTimer.seconds == 90)
    #expect(layout.objects.contains { $0.textLink?.source == .timer && $0.textLink?.timerId == AnnouncementsTimer.id })
    #expect(layout.objects.contains { $0.textLink?.source == .clock })
    #expect(layout.objects.contains { $0.objectKind == .shape && $0.name == ConfidenceLayoutTemplate.audienceBoxName })
    #expect(BasicTemplates.stageLayouts().contains { $0.id == BasicTemplates.announcementsStageID })
}

@Test func theClosingSongIsKnownByItsNameOrItsPlace() {
    let closing = ServiceItem(id: "c", itemKind: .presentation, name: "Closing Song", refId: "song")
    let song = ServiceItem(id: "s", itemKind: .presentation, name: "Goodness of God", refId: "song")
    #expect(StandingItems.isClosingSong(closing, position: nil))
    #expect(StandingItems.isClosingSong(song, position: .closing))
    #expect(!StandingItems.isClosingSong(song, position: .song(2)))
    #expect(!StandingItems.isClosingSong(ServiceItem(id: "h", itemKind: .header, name: "Closing", refId: ""), position: .closing))
}

@Test func aChosenFrameIsTheVideosThumbnail() {
    var clip = MediaItem(
        id: "v", name: "v", mediaKind: .video, classification: .foreground, fileHash: "h", fileName: "v.mov",
        fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: false)
    clip.inPoint = 4
    #expect(MediaPosterStore.posterTime(of: clip) == 4)
    let before = MediaPosterStore.fingerprint(of: clip)
    #expect(before == MediaPosterStore.fingerprint(fileHash: "h", inPoint: 4), "posters already on disk are still found")
    clip.posterSeconds = 12.5
    #expect(MediaPosterStore.posterTime(of: clip) == 12.5)
    #expect(MediaPosterStore.fingerprint(of: clip) != before)
}
