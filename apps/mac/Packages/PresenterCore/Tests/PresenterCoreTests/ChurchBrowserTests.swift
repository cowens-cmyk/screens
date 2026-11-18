import Foundation
import Testing
@testable import PresenterCore

@Suite struct ChurchBrowserTests {
    @Test func theBrowserSlideIsThePageEdgeToEdge() throws {
        let deck = ChurchBrowser.presentation()
        #expect(deck.id == ChurchBrowser.presentationID)
        #expect(deck.canvasWidth == 1920 && deck.canvasHeight == 1080)
        let slide = try #require(deck.slides.first)
        #expect(deck.slides.count == 1)
        let page = try #require(slide.objects.first)
        #expect(page.fill?.liveInputId == ChurchBrowser.inputID)
        #expect(page.x == 0 && page.y == 0 && page.width == 1920 && page.height == 1080)
        #expect(ChurchBrowser.shows(slide))
        #expect(!ChurchBrowser.shows(Slide(id: "s", name: "", objects: [])))
    }

    @Test func findsTheBrowserByIDThenByName() {
        #expect(ChurchBrowser.find(ids: [("x", "Browser"), ("browser", "Web")]) == "browser")
        #expect(ChurchBrowser.find(ids: [("b", " browser "), ("a", "Browser")]) == "a")
        #expect(ChurchBrowser.find(ids: [("a", "Announcements")]) == nil)
    }

    @Test func aBrowserSlideOpensItsOwnSite() throws {
        let slide = ChurchBrowser.slide(site: "hopejc.org/events", width: 1280, height: 720)
        #expect(ChurchBrowser.shows(slide))
        #expect(ChurchBrowser.site(on: slide) == "https://hopejc.org/events")
        #expect(slide.name == "hopejc.org/events")
        let page = try #require(slide.objects.first)
        #expect(page.width == 1280 && page.height == 720)
        #expect(ChurchBrowser.site(on: ChurchBrowser.slide(site: nil)) == nil)
        #expect(ChurchBrowser.site(on: ChurchBrowser.presentation().slides[0]) == nil)
    }

    @Test func changingTheSiteRenamesOnlyASlideNamedForIt() {
        let slide = ChurchBrowser.slide(site: "https://www.youtube.com")
        #expect(slide.name == "youtube.com")
        let moved = ChurchBrowser.setting(site: "hopejc.org", on: slide)
        #expect(ChurchBrowser.site(on: moved) == "https://hopejc.org")
        #expect(moved.name == "hopejc.org")
        var named = slide
        named.name = "Giving video"
        #expect(ChurchBrowser.setting(site: "hopejc.org", on: named).name == "Giving video")
    }

    @Test func typedSitesBecomeAddresses() {
        #expect(ChurchBrowser.normalized(" hopejc.org ") == "https://hopejc.org")
        #expect(ChurchBrowser.normalized("http://10.1.2.5:8080/x") == "http://10.1.2.5:8080/x")
        #expect(ChurchBrowser.normalized("not a site") == nil)
        #expect(ChurchBrowser.normalized("hello") == nil)
        #expect(ChurchBrowser.normalized("") == nil)
    }
}
