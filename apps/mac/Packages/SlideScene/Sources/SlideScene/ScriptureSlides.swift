import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

/// Turns a fetched passage into slides laid out by the theme's "Bible" slide.
/// Text is measured against that slide's real placeholder (font, size,
/// insets, shrink limit), so a slide only ends where the next verse wouldn't
/// fit, and the next slide begins with that verse.
public enum ScriptureSlideBuilder {

    public static let themeSlideName = "Bible"
    public static let scriptureObjectName = "Verse"
    public static let referenceObjectName = "Reference"

    public static func slides(
        for passage: BiblePassage,
        format: ScriptureFormat,
        theme: Theme?,
        themeSlideName: String = themeSlideName,
        canvasSize: CGSize = SlideSceneBuilder.canvasSize
    ) -> [Slide] {
        let probe = Slide(id: "probe", name: "", objects: [], themeSlideName: themeSlideName)
        let template = SlideSceneBuilder.themeSlide(for: probe, theme: theme)
        let textPlaceholders = template?.objects.filter { $0.objectKind == .text } ?? []
        // A template with its own reference box gets the reference there;
        // otherwise it follows the verses in the same box.
        let separateReference = textPlaceholders.count >= 2
        let book = passage.reference.book
        let abbreviation = passage.translation.abbreviation

        func referenceLine(_ page: ScripturePage) -> String {
            "\(page.reference(book: book)) \(abbreviation)"
        }
        func objects(text: String, reference: String) -> [SlideObject] {
            if separateReference {
                return [
                    SlideObject(id: UUID().uuidString, objectKind: .text, name: scriptureObjectName, text: text),
                    SlideObject(id: UUID().uuidString, objectKind: .text, name: referenceObjectName, text: reference),
                ]
            }
            return [SlideObject(
                id: UUID().uuidString, objectKind: .text, name: scriptureObjectName,
                text: "\(text)\n\(reference)")]
        }
        func fits(_ text: String) -> Bool {
            guard let template else { return text.count <= 280 }
            // Measure with the longest reference this passage could show.
            let reference = "\(passage.reference.display) \(abbreviation)"
            let candidate = objects(text: text, reference: reference)
            let assignments = SlideSceneBuilder.placeholderAssignments(for: candidate, in: template)
            let item = SlideSceneBuilder.renderItem(
                for: candidate[0], theme: theme, placeholder: assignments[candidate[0].id], in: canvasSize)
            guard case .text(let styled) = item.content else { return true }
            return !TextRasterizer.overflows(styled, sceneFrame: item.frame.size)
        }

        let pages = ScripturePaginator.paginate(passage.verses, format: format, fits: fits)
        return pages.map { page in
            var slide = Slide(
                id: UUID().uuidString, name: page.reference(book: book),
                objects: objects(text: page.text, reference: referenceLine(page)))
            slide.themeSlideName = themeSlideName
            return slide
        }
    }

    public static func presentation(
        for passage: BiblePassage,
        format: ScriptureFormat,
        theme: Theme?,
        folder: String? = nil
    ) -> Presentation {
        var presentation = Presentation(
            id: UUID().uuidString,
            name: "\(passage.reference.display) (\(passage.translation.abbreviation))",
            presentationKind: .deck,
            themeId: theme?.id ?? "",
            folder: folder,
            slides: slides(for: passage, format: format, theme: theme)
        )
        presentation.category = PresentationTypes.bible
        if let copyright = passage.copyright, !copyright.isEmpty {
            for index in presentation.slides.indices { presentation.slides[index].notes = copyright }
        }
        return presentation
    }
}
