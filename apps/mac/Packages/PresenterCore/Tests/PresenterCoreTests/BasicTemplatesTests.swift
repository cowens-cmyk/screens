import Foundation
import Testing
@testable import PresenterCore

@Test func basicThemesTieEachCategoryToItsLowerThird() {
    let themes = BasicTemplates.themes()
    #expect(themes.map(\.name) == ["Worship", "Scripture", "Points"])
    for theme in themes {
        let slides = theme.slides ?? []
        let tie = theme.streamDesigns?.first
        #expect(tie?.mode == .design && tie?.themeId == theme.id)
        let lower = slides.first { $0.id == tie?.slideId }
        #expect(lower?.folder == BasicTemplates.lowerThirds, "\(theme.name) ties to its own lower third")
        #expect(slides.contains { $0.name == tie?.category && $0.folder == nil }, "\(theme.name) has the full-screen design")
        // The bar first and the text after it: the last object is drawn on top.
        #expect(lower?.objects.first?.name == "Bar" && lower?.objects.last?.objectKind == .text)
    }
    #expect(BasicTemplates.stageLayouts().map(\.id) == [BasicTemplates.worshipStageID, BasicTemplates.messageStageID])
}
