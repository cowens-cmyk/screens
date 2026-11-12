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

/// Sunday's plan, as Shepherd lays it out: four songs, the message, then a
/// CLOSING SONG header over the song, the Close slide and the Walkout.
private func sundayItems() -> [ServiceItem] {
    func song(_ id: String, _ title: String) -> ServiceItem {
        var item = ServiceItem(id: id, itemKind: .presentation, name: title, refId: "deck-\(id)")
        item.mxuSongTitle = title
        return item
    }
    var walkout = ServiceItem(id: "walkout", itemKind: .presentation, name: "Walkout", refId: "closing-deck")
    walkout.isWalkout = true
    return [
        ServiceItem(id: "h1", itemKind: .header, name: "WORSHIP", refId: ""),
        song("s1", "One"), song("s2", "Two"), song("s3", "Three"), song("s4", "Four"),
        ServiceItem(id: "h2", itemKind: .header, name: "MESSAGE", refId: ""),
        ServiceItem(id: "msg", itemKind: .presentation, name: "Message", refId: "msg-deck"),
        ServiceItem(id: "h3", itemKind: .header, name: "CLOSING SONG", refId: ""),
        song("s5", "The Lord Is With Me"),
        ServiceItem(id: "close", itemKind: .presentation, name: "Close", refId: "closing-deck"),
        walkout,
    ]
}

@Test func theClosingSongLightsAsSongFiveAndClosingWaitsForTheClose() {
    let items = sundayItems()
    let positions = ServicePosition.positions(in: items)
    #expect(positions["s4"] == .song(4))
    #expect(positions["s5"] == .song(5), "the closing song is a song scene, not Closing")
    #expect(positions["close"] == .closing)
    #expect(positions["walkout"] == .walkout, "not the header's Closing")
    #expect(positions["msg"] == .message)

    // It is still the Closing Song for the Sermon timer; the Walkout isn't.
    #expect(StandingItems.isClosingSong(items[8], in: items, position: positions["s5"]))
    #expect(!StandingItems.isClosingSong(items[10], in: items, position: positions["walkout"]))
    #expect(!StandingItems.isClosingSong(items[1], in: items, position: positions["s1"]))

    // A Close item on its own, with no header over it, is Closing by name.
    #expect(ServicePosition.named("Close") == .closing)
    #expect(ServicePosition.named("Closing Song") == .closing)
    #expect(ServicePosition.named("Enclosed") == nil)

    // A header pointed at Closing by hand keeps its songs there.
    var chosen = items
    chosen[7].lightingCue = ServicePosition.closing.key
    #expect(ServicePosition.positions(in: chosen)["s5"] == .closing)
}

@Test func theWalkoutTakesTheWholeLivestream() {
    let items = sundayItems()
    let plan = Service(id: "p", name: "", serviceDate: "", items: items)
    let closing = Presentation(
        id: "closing-deck", name: "Closing", presentationKind: .deck, themeId: "",
        slides: [Slide(id: "logo", name: "Logo", objects: [], streamDesign: StreamDesign(category: "", mode: .clear))])
    let library = StageStreamTags.Library(
        presentation: { $0 == "closing-deck" ? closing : nil }, media: { _ in nil }, theme: { _ in nil }, settings: nil)
    // The same slide: camera only as the Close, the whole stream as the Walkout.
    #expect(StageStreamTags.tags(for: items[9], in: plan, library: library)?.stream == "Camera only")
    #expect(StageStreamTags.tags(for: items[10], in: plan, library: library)?.stream == "Full screen")
    #expect(StageStreamTags.tags(for: items[10], in: plan, library: library)?.stage == "Before service")
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
