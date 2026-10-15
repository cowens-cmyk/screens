import Foundation
import PresenterCore
import Testing
@testable import SlideScene

@MainActor
struct PagingIdentityTests {
    @Test func secondPageGetsItsOwnStableSlideID() throws {
        var style = TextStyle(fontName: "Helvetica", fontSize: 40)
        style.pageOnClick = true
        var placeholder = SlideObject(
            id: "placeholder", objectKind: .text, name: "Body", text: "Sample",
            textStyle: style)
        placeholder.x = 0
        placeholder.y = 0
        placeholder.width = 400
        placeholder.height = 120
        let theme = Theme(
            id: "theme", name: "Paged", fontFamily: "Helvetica", fontSize: 40,
            textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
            slides: [Slide(id: "template", name: "Paged", objects: [placeholder])])
        let slide = Slide(
            id: "source", name: "Reading",
            objects: [SlideObject(
                id: "body", objectKind: .text, name: "Body",
                text: (1...12).map { "Line \($0)" }.joined(separator: "\n"))],
            themeSlideName: "Paged")

        let pages = Paging.pages(of: slide, theme: theme)
        try #require(pages.count >= 3)
        #expect(pages[0].id == "source")
        #expect(pages[1].id == "source::page::2")
        #expect(pages[2].id == "source::page::3")
        #expect(Set(pages.map(\.id)).count == pages.count)
    }
}
