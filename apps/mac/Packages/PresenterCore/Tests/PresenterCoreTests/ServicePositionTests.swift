import Foundation
@testable import PresenterCore
import Testing

struct ServicePositionTests {
    private func item(
        _ id: String, _ kind: ServiceItemKind = .presentation, name: String? = nil, refId: String? = nil
    ) -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: name ?? id, refId: refId ?? id)
    }

    private func header(_ id: String, _ name: String) -> ServiceItem {
        ServiceItem(id: id, itemKind: .header, name: name, refId: "")
    }

    /// Categories by presentation id, the way the app reads them from decks.
    private func facts(_ categories: [String: String], preService: Set<String> = []) -> (ServiceItem) -> ServicePosition.ItemFacts {
        { item in
            ServicePosition.ItemFacts(category: categories[item.refId], isPreService: preService.contains(item.refId))
        }
    }

    @Test func keysRoundTrip() {
        let all: [ServicePosition] = ServicePosition.standard(songs: 7) + [.custom("Prayer")]
        for position in all {
            #expect(ServicePosition(key: position.key) == position)
        }
        #expect(ServicePosition(key: "song0") == nil)
        #expect(ServicePosition(key: "custom:") == nil)
        #expect(ServicePosition(key: "none") == nil)
        #expect(ServicePosition.song(3).title == "Song 3")
    }

    @Test func headerNamesNormalize() {
        #expect(ServicePosition.named("Walk In") == .walkIn)
        #expect(ServicePosition.named("Walk-in") == .walkIn)
        #expect(ServicePosition.named("PRE-SERVICE") == .walkIn)
        #expect(ServicePosition.named("Welcome & Announcements") == .announcements)
        #expect(ServicePosition.named("Message") == .message)
        #expect(ServicePosition.named("Sermon") == .message)
        #expect(ServicePosition.named("Benediction") == .closing)
        #expect(ServicePosition.named("Walk Out") == .walkout)
        #expect(ServicePosition.named("Post-Service") == .walkout)
        #expect(ServicePosition.named("Baptism") == .baptism)
        #expect(ServicePosition.named("The Lord's Supper") == .communion)
        #expect(ServicePosition.named("Worship") == nil)
        #expect(ServicePosition.named("Response") == nil)
        #expect(ServicePosition.named("prayer time", customNames: ["Prayer Time"]) == .custom("Prayer Time"))
    }

    /// The church's order: songs number themselves around the announcements
    /// and the message, and the countdown and walk-in slideshow are found by
    /// what they are.
    @Test func aTemplateOrderGivesEveryPosition() {
        var countdown = item("cd", .media)
        countdown.isCountdown = true
        let items = [
            header("h0", "Pre-Service"),
            item("loop"),
            countdown,
            header("h1", "Worship"),
            item("s1"), item("s2"),
            item("ann"),
            item("s3"), item("s4"),
            header("h2", "Message"),
            item("msg"),
            header("h3", "Response"),
            item("s5"),
            item("close", name: "Closing"),
            item("out", name: "Walkout"),
        ]
        let worship = PresentationTypes.worship
        let positions = ServicePosition.positions(
            in: items,
            facts: facts([
                "s1": worship, "s2": worship, "s3": worship, "s4": worship, "s5": worship,
                "ann": PresentationTypes.announcements, "msg": PresentationTypes.sermon,
            ]))
        #expect(positions["loop"] == .walkIn)
        #expect(positions["cd"] == .countdown, "the countdown is its own scene even under a walk-in header")
        #expect(positions["s1"] == .song(1))
        #expect(positions["s2"] == .song(2))
        #expect(positions["ann"] == .announcements)
        #expect(positions["s3"] == .song(3))
        #expect(positions["s4"] == .song(4))
        #expect(positions["msg"] == .message)
        #expect(positions["s5"] == .song(5))
        #expect(positions["close"] == .closing)
        #expect(positions["out"] == .walkout)
        #expect(positions["h1"] == nil && positions["h3"] == nil)
        #expect(positions["h2"] == .message)
    }

    @Test func aHeaderNamesTheItemsUnderIt() {
        let items = [
            header("h", "Baptism"),
            item("video", .media),
            item("song"),
            header("w", "Worship"),
            item("next"),
        ]
        let worship = PresentationTypes.worship
        let positions = ServicePosition.positions(in: items, facts: facts(["song": worship, "next": worship]))
        #expect(positions["video"] == .baptism)
        #expect(positions["song"] == .baptism)
        #expect(positions["next"] == .song(1), "a song under a named header doesn't take a number")
    }

    @Test func overridesWinAndNoneSilences() {
        var first = item("a")
        first.lightingCue = "none"
        var second = item("b")
        second.lightingCue = ServicePosition.communion.key
        var third = item("c")
        third.lightingCue = "garbage"
        var named = header("h", "Something")
        named.lightingCue = ServicePosition.baptism.key
        let items = [first, second, third, named, item("d")]
        let worship = PresentationTypes.worship
        let positions = ServicePosition.positions(
            in: items, facts: facts(["a": worship, "b": worship, "c": worship]))
        #expect(positions["a"] == nil)
        #expect(positions["b"] == .communion)
        #expect(positions["c"] == .song(1), "an unreadable choice is no choice")
        #expect(positions["d"] == .baptism, "a header's choice reaches its items")
    }

    @Test func hiddenItemsTakeNoNumber() {
        var hidden = item("x")
        hidden.hiddenInPresenter = true
        let items = [item("a"), hidden, item("b")]
        let worship = PresentationTypes.worship
        let positions = ServicePosition.positions(
            in: items, facts: facts(["a": worship, "x": worship, "b": worship]))
        #expect(positions["x"] == nil)
        #expect(positions["b"] == .song(2))
    }

    @Test func plannedSongsWithoutSlidesStillCount() {
        var planned = ServiceItem(id: "p", itemKind: .info, name: "Way Maker", refId: "")
        planned.mxuSongTitle = "Way Maker"
        let positions = ServicePosition.positions(
            in: [planned, item("b")], facts: facts(["b": PresentationTypes.worship]))
        #expect(positions["p"] == .song(1))
        #expect(positions["b"] == .song(2))
    }

    @Test func thePlansMessageIsTheMessage() {
        let positions = ServicePosition.positions(in: [item("deck")], messagePresentationId: "deck")
        #expect(positions["deck"] == .message)
    }

    @Test func preServiceSlideshowIsRecognized() {
        #expect(ServicePosition.isPreServiceSlideshow(id: "a", name: "Anything", loops: false, preServicePresentationId: "a"))
        #expect(ServicePosition.isPreServiceSlideshow(id: "a", name: "Pre-Service Loop", loops: true, preServicePresentationId: nil))
        #expect(!ServicePosition.isPreServiceSlideshow(id: "a", name: "Pre-Service Loop", loops: false, preServicePresentationId: nil))
        #expect(!ServicePosition.isPreServiceSlideshow(id: "a", name: "Announcements", loops: true, preServicePresentationId: "b"))
    }

    @Test func cueTableDefaultsStayClearOfSectionAndActionNotes() {
        let table = LightingCueTable.defaults
        #expect(table.count == 13)
        #expect(table.map(\.note) == Array(60...72))
        #expect(LightingCueTable.note(for: .walkIn, in: table) == 60)
        #expect(LightingCueTable.note(for: .song(1), in: table) == 62)
        #expect(LightingCueTable.note(for: .communion, in: table) == 72)
        // Song sections send 1–10 and the Lightkey Cue action 31–54.
        #expect(table.allSatisfy { row in !LightingCueTable.reservedNotes.contains { $0.contains(row.note) } })
        #expect(LightingCueTable.effective(nil) == table)
        #expect(LightingCueTable.effective([]) == table)
        #expect(LightingCueTable.nextFreeNote(in: table) == 73)
    }

    @Test func addedCuesNeverTakeAReservedNote() {
        var table = LightingCueTable.defaults
        // Everything above the defaults taken: the next free one is below
        // them, skipping 31–54 and 1–10.
        table += (73...127).map { LightingCue(position: ServicePosition.custom("C\($0)").key, note: $0) }
        var handed: [Int] = []
        // 59–55 and 30–11 are all that's left.
        for _ in 0..<25 {
            let note = LightingCueTable.nextFreeNote(in: table)
            handed.append(note)
            table.append(LightingCue(position: ServicePosition.custom("N\(note)").key, note: note))
        }
        #expect(handed.prefix(5) == [59, 58, 57, 56, 55])
        #expect(handed[5] == 30)
        #expect(handed.last == 11)
        #expect(handed.allSatisfy { note in !LightingCueTable.reservedNotes.contains { $0.contains(note) } })
        #expect(Set(handed).count == handed.count)
    }

    @Test func anItemGoesLiveOncePerVisit() {
        var tracker = LiveItemTracker()
        // Song 1's next slide doesn't send the cue or run its macros again;
        // back to Song 1 after Song 2 is a new visit.
        let keys = ["song1", "song1", "song2", "song1",
                    LiveItemTracker.preServiceKey("loop"), LiveItemTracker.preServiceKey("loop")]
        let fresh = keys.map { tracker.wentLive($0) }
        #expect(fresh == [true, false, true, true, true, false])
        #expect(tracker.current == "preService|loop")
    }

    @Test func laterSongsUseTheLastSongRow() {
        var table = LightingCueTable.defaults
        #expect(LightingCueTable.note(for: .song(6), in: table) == 66)
        #expect(LightingCueTable.note(for: .song(9), in: table) == 66)
        #expect(LightingCueTable.songCount(in: table) == 5)
        table.append(LightingCue(position: ServicePosition.song(6).key, note: 73))
        #expect(LightingCueTable.note(for: .song(7), in: table) == 73)
        #expect(LightingCueTable.songCount(in: table) == 6)

        let index = table.firstIndex { $0.position == "message" }!
        table[index].off = true
        #expect(LightingCueTable.note(for: .message, in: table) == nil)
        #expect(LightingCueTable.note(for: .custom("Prayer"), in: table) == nil)
        table.append(LightingCue(position: ServicePosition.custom("Prayer").key, note: 74))
        #expect(LightingCueTable.note(for: .custom("Prayer"), in: table) == 74)
        #expect(LightingCueTable.customNames(in: table) == ["Prayer"])
    }

    @Test func aMacroWithALightkeyCueIsSeenThroughCombos() {
        var cue = SlideAction(id: "1", kind: .midiOut)
        cue.midiDeviceId = "lightkey"
        var other = SlideAction(id: "2", kind: .midiOut)
        other.midiDeviceId = "console"
        var fire = SlideAction(id: "3", kind: .fireCombo)
        fire.comboId = "outer"
        var loop = SlideAction(id: "4", kind: .fireCombo)
        loop.comboId = "loop"
        var fireInner = SlideAction(id: "5", kind: .fireCombo)
        fireInner.comboId = "inner"
        let combos: [String: [SlideAction]] = ["outer": [other, fireInner], "inner": [cue], "loop": [loop]]
        let lookup = { (id: String) in combos[id] }
        #expect(LightingCueTable.sendsLightkeyCue([cue], lightkeyDeviceID: "lightkey", combo: lookup))
        #expect(!LightingCueTable.sendsLightkeyCue([other], lightkeyDeviceID: "lightkey", combo: lookup))
        #expect(LightingCueTable.sendsLightkeyCue([fire], lightkeyDeviceID: "lightkey", combo: lookup))
        #expect(!LightingCueTable.sendsLightkeyCue([loop], lightkeyDeviceID: "lightkey", combo: lookup))
    }
}
