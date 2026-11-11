import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

/// Measures song slides the way the audience sees them, for LyricSlideFit:
/// the words in the theme's real Lyrics placeholder (font, size, insets,
/// box width), at the size they're drawn, wraps included.
public enum LyricSlideFitter {

    /// Lines counted for slides drawn with the theme `theme(slide)` gives,
    /// on a canvas this size. Chords are left off: the audience doesn't see
    /// them and they don't change where the words wrap.
    public static func lineCount(
        theme: @escaping @Sendable (Slide) -> Theme?,
        canvasSize: CGSize = SlideSceneBuilder.canvasSize
    ) -> LyricSlideFit.LineCount {
        { slide, box, text in
            let slideTheme = theme(slide)
            // A design picked for this theme draws the slide instead of
            // its own (Slide.rendered(throughOverride:)).
            let drawn = slideTheme.map { slide.rendered(throughOverride: $0) } ?? slide
            let template = drawn.unthemed == true ? nil : SlideSceneBuilder.themeSlide(for: drawn, theme: slideTheme)
            var candidate = box
            candidate.text = text
            candidate.chords = nil
            let objects = drawn.objects.map { $0.id == box.id ? candidate : $0 }
            let assignments = SlideSceneBuilder.placeholderAssignments(for: objects, in: template)
            let item = SlideSceneBuilder.renderItem(
                for: candidate, theme: slideTheme, placeholder: assignments[candidate.id], in: canvasSize)
            guard case .text(let styled) = item.content else { return nil }
            return TextRasterizer.wrappedLineCount(for: styled, sceneFrame: item.frame.size)
        }
    }

    /// `presentation` with its slides split to two lines at most, measured
    /// in the themes `themes` holds (by id), the presentation's own for
    /// each slide. A slide with no theme to measure in is left alone: its
    /// box size isn't known.
    public static func fit(_ presentation: Presentation, themes: [String: Theme]) -> LyricSlideFit.Result {
        let owner = presentation
        let measure = lineCount(
            theme: { slide in themes[owner.themeId(for: slide)] },
            canvasSize: SlideSceneBuilder.canvasSize(for: presentation))
        let counter: LyricSlideFit.LineCount = { slide, box, text in
            guard themes[owner.themeId(for: slide)] != nil else { return nil }
            return measure(slide, box, text)
        }
        return LyricSlideFit.fit(presentation, lineCount: counter)
    }
}
