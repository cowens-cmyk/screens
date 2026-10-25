import Foundation
import Testing
@testable import PresenterCore

// A series theme built from art must always come out usable on the audience
// screens: every design has its text boxes, the text is drawn over the art
// (the renderer draws a design's objects in order, the last on top), and
// the text reads on what is really behind it.

private let families = ["Helvetica Neue", "Avenir Next"]

private func hex(_ value: String) -> SeriesColor { SeriesColor(hex: value)! }

private func analysis(textColor: String, tone: ArtAnalysis.Tone, swatches: [String]) -> ArtAnalysis {
    var analysis = ArtAnalysis.local(
        swatches: swatches.map { SeriesPalette.Swatch(color: hex($0), share: 1 / Double(swatches.count)) },
        seriesTitle: "Rooted")
    analysis.textColor = textColor
    analysis.textBackground = .init(kind: .blurredArt, tone: tone, strength: 0.5, blur: 0.6, colors: [])
    return analysis.sanitized(installedFamilies: families)
}

/// What PhotoSeries.save hands the builder: the art for the Title slide and
/// a background made from it, with colors measured where text sits.
private func input(_ analysis: ArtAnalysis, background: [SeriesColor], title: [SeriesColor],
                   kind: PhotoSeriesTheme.Kind = .sermonSeries) -> PhotoSeriesTheme.Input {
    PhotoSeriesTheme.Input(
        name: "Rooted", analysis: analysis, headingFont: "HelveticaNeue-Bold", bodyFont: "HelveticaNeue",
        verseFont: "HelveticaNeue", titleArtMediaID: "art", artWidth: 1920, artHeight: 1080,
        textBackgroundMediaID: "soft", textBackgroundSamples: background, titleSamples: title, kind: kind)
}

private func alpha(of hex: String?) -> Double {
    Double(Int(hex?.suffix(2) ?? "FF", radix: 16) ?? 255) / 255
}

/// Every full-screen design has the text boxes its slides need, drawn over
/// everything else, in a color that reads on `background` (or `title` for
/// the Title slide over the art) once any scrim in the design is laid on.
private func expectReadable(_ theme: Theme, background: [SeriesColor], title: [SeriesColor],
                            sourceLocation: SourceLocation = #_sourceLocation) {
    let designs = theme.slides ?? []
    #expect(!designs.isEmpty, sourceLocation: sourceLocation)
    for design in designs {
        let lower = SermonSeriesTheme.isLowerThird(design)
        let texts = design.objects.filter { $0.objectKind == .text }
        let names = Set(texts.map(\.name))
        for name in SermonSeriesTheme.requiredText(for: design) {
            #expect(names.contains(name), "\(design.name) has its \(name) box", sourceLocation: sourceLocation)
        }
        let firstText = design.objects.firstIndex { $0.objectKind == .text } ?? 0
        let lastShape = design.objects.lastIndex { $0.objectKind != .text } ?? -1
        #expect(lastShape < firstText, "\(design.name): text is drawn over the art and bars", sourceLocation: sourceLocation)
        guard !lower else { continue }

        let onArt = design.name == SermonSeriesTheme.titleCategory && design.objects.contains { $0.fill?.mediaId == "art" }
        var behind = onArt ? title : background
        if let scrim = design.objects.first(where: { $0.name == "Scrim" }), let color = scrim.fill?.colorHex {
            behind = behind.map { hex(color).composited(alpha: alpha(of: color), over: $0) }
        }
        for text in texts {
            let color = hex(text.textStyle?.colorHex ?? "#000000")
            // Body text is held to 7:1 for the projector; headings over the
            // art and accent lines (references, subtitles) to 4.5:1. Colors
            // are stored as bytes, which can cost a hair of contrast.
            let body = !onArt && ["Point", "Verse", "Lyrics", "Body", "Title"].contains(text.name)
            #expect(SeriesContrast.worst(color, on: behind) >= (body ? 6.9 : 4.4),
                    "\(design.name) \(text.name): \(color.hex()) reads", sourceLocation: sourceLocation)
        }
    }
}

// MARK: The art

@Test func darkArtGetsLightTextOverIt() throws {
    let navy = [hex("#0B1426"), hex("#15233F"), hex("#1E2F52")]
    let made = input(analysis(textColor: "#FFFFFF", tone: .dark, swatches: ["#0B1426", "#D9A441"]),
                     background: navy, title: navy)
    let theme = PhotoSeriesTheme.make(made)
    expectReadable(theme, background: navy, title: navy)
    let colors = PhotoSeriesTheme.colors(for: made)
    #expect(colors.text.luminance > 0.8 && colors.textScrim == 0, "white on navy needs no help")
}

@Test func lightArtGetsDarkTextEvenWhenAskedForWhite() throws {
    // The report: cream series art, and the scripture design came out as
    // the art alone. White text was asked for; it can't read on cream.
    let cream = [hex("#F4EEDF"), hex("#EDE3CC"), hex("#FBF8F1")]
    let made = input(analysis(textColor: "#FFFFFF", tone: .light, swatches: ["#F4EEDF", "#8A5A2B"]),
                     background: cream, title: cream)
    let theme = PhotoSeriesTheme.make(made)
    expectReadable(theme, background: cream, title: cream)
    #expect(PhotoSeriesTheme.colors(for: made).text.luminance < 0.2)
}

@Test func bodyTextThatOnlyJustPassesIsMadeStronger() throws {
    // Grey on charcoal is 5:1, a pass on paper and weak on a projector.
    let charcoal = [hex("#1A1A1A")]
    let grey = hex("#8A8A8A")
    #expect(SeriesContrast.worst(grey, on: charcoal) > 4.5 && SeriesContrast.worst(grey, on: charcoal) < 7)
    let made = input(analysis(textColor: grey.hex(), tone: .dark, swatches: ["#1A1A1A"]), background: charcoal, title: charcoal)
    let colors = PhotoSeriesTheme.colors(for: made)
    #expect(SeriesContrast.worst(colors.text, on: charcoal) >= 7)
    #expect(colors.text.luminance > grey.luminance, "lightened, not swapped for another color")
    expectReadable(PhotoSeriesTheme.make(made), background: charcoal, title: charcoal)

    // Picked by hand, it's used as picked: it already reads at 4.5:1.
    var picked = made
    picked.textColorOverride = grey
    let pickedColors = PhotoSeriesTheme.colors(for: picked)
    #expect(pickedColors.text == grey && pickedColors.textScrim == 0)
}

@Test func busyMidToneArtGetsAScrim() throws {
    // Black, white and mid grey all behind the same lines: no text color
    // alone reaches 4.5:1, so a veil goes between the art and the text.
    let busy = [hex("#000000"), hex("#FFFFFF"), hex("#777777"), hex("#B04030"), hex("#3060A0")]
    let made = input(analysis(textColor: "#FFFFFF", tone: .dark, swatches: ["#777777", "#B04030", "#3060A0"]),
                     background: busy, title: busy)
    let colors = PhotoSeriesTheme.colors(for: made)
    #expect(colors.textScrim > 0 && colors.textScrim < 1)
    #expect(colors.titleScrim > 0)
    let theme = PhotoSeriesTheme.make(made)
    expectReadable(theme, background: busy, title: busy)
    #expect(colors.textPlate, "busy art gets a plate behind the text, not a veil over all of it")
    for category in [SermonSeriesTheme.pointCategory, SermonSeriesTheme.scriptureCategory,
                     SermonSeriesTheme.pointScriptureCategory, SermonSeriesTheme.worshipCategory] {
        let design = try #require(theme.slides?.first { $0.name == category && $0.folder == nil })
        let plate = try #require(design.objects.first { $0.name == "Scrim" }, "\(category)")
        #expect(plate.shapeKind == .roundedRectangle && (plate.width ?? 1920) < 1920, "\(category)")
        #expect(alpha(of: plate.fill?.colorHex) >= 0.59, "\(category): solid enough to quiet the art")
        for text in design.objects where text.objectKind == .text {
            let inside = (text.x ?? 0) >= (plate.x ?? 0) && (text.y ?? 0) >= (plate.y ?? 0)
                && (text.x ?? 0) + (text.width ?? 0) <= (plate.x ?? 0) + (plate.width ?? 0)
                && (text.y ?? 0) + (text.height ?? 0) <= (plate.y ?? 0) + (plate.height ?? 0)
            #expect(inside, "\(category) \(text.name) sits on the plate")
        }
    }
    let point = try #require(theme.slides?.first { $0.name == SermonSeriesTheme.pointCategory })
    #expect(point.objects.map(\.name) == ["Series Art", "Scrim", "Point"], "art, then the plate, then the words")
    let title = try #require(theme.slides?.first { $0.name == SermonSeriesTheme.titleCategory })
    let plate = try #require(title.objects.first { $0.name == "Scrim" })
    #expect((plate.width ?? 1920) < 1920, "on the Title slide only behind the title, not over the whole art")
}

@Test func aGeneralThemeFromBusyArtIsAsReadable() throws {
    let busy = [hex("#000000"), hex("#FFFFFF"), hex("#808080")]
    let theme = PhotoSeriesTheme.make(input(
        analysis(textColor: "#FFFFFF", tone: .dark, swatches: ["#808080"]), background: busy, title: busy, kind: .general))
    expectReadable(theme, background: busy, title: busy)
}

@Test func lowerThirdsAreDrawnUnderTheirText() throws {
    let navy = [hex("#0B1426")]
    let theme = PhotoSeriesTheme.make(input(
        analysis(textColor: "#FFFFFF", tone: .dark, swatches: ["#0B1426", "#D9A441"]), background: navy, title: navy))
    let lower = try #require(theme.slides?.first { $0.name == "Bible (Lower Third)" })
    let names = lower.objects.map(\.name)
    #expect(names.first == "Bar")
    #expect(names.suffix(2) == ["Verse", "Reference"], "the verse is drawn on the bar, not dimmed under it")
    if let rule = names.firstIndex(of: "Accent Rule") {
        #expect(rule > 0, "the accent rule sits on the bar")
    }
}

@Test func anImageBarThatTextCantReadOnGetsAScrim() throws {
    let navy = [hex("#0B1426")]
    var made = input(analysis(textColor: "#FFFFFF", tone: .dark, swatches: ["#0B1426"]), background: navy, title: navy)
    made.lowerThirdMediaID = "bar-art"
    made.lowerThirdSamples = [hex("#000000"), hex("#FFFFFF"), hex("#808080")]
    let theme = PhotoSeriesTheme.make(made)
    let lower = try #require(theme.slides?.first { $0.name == "Bible (Lower Third)" })
    #expect(lower.objects.map(\.name) == ["Series Lower Third", "Scrim", "Verse", "Reference"])
    let scrim = try #require(lower.objects.first { $0.name == "Scrim" }?.fill?.colorHex)
    let behind = made.lowerThirdSamples.map { hex(scrim).composited(alpha: alpha(of: scrim), over: $0) }
    let verse = try #require(lower.objects.first { $0.name == "Verse" }?.textStyle?.colorHex)
    #expect(SeriesContrast.worst(hex(verse), on: behind) >= 4.4)
}

@Test func aSeriesDrawnFromItsNameIsCheckedAgainstItsArtwork() throws {
    // Claude drew a cream background and asked for white text on it, and a
    // bar with nothing solid where the text goes.
    let cream = [hex("#F4EEDF"), hex("#EDE3CC")]
    let style = SermonSeriesStyle(name: "Rooted", backgroundMediaID: "bg", lowerThirdMediaID: "bar",
                                  textColor: "#FFFFFFFF", accentColor: "#FFF4D6FF",
                                  lowerThirdTextColor: "#FFFFFFFF", lowerThirdAccentColor: "#FFB21EFF")
    let theme = PhotoSeriesTheme.make(style, backgroundSamples: cream, barSamples: [])
    let designs = theme.slides ?? []
    #expect(designs.count == 9)
    for design in designs where !SermonSeriesTheme.isLowerThird(design) {
        #expect(design.objects.first?.fill?.mediaId == "bg", "\(design.name)")
        for text in design.objects where text.objectKind == .text {
            #expect(SeriesContrast.worst(hex(text.textStyle?.colorHex ?? ""), on: cream) >= 4.4, "\(design.name) \(text.name)")
        }
    }
    // Over the camera shot, the lower third gets a scrim under its text.
    let lower = try #require(designs.first { $0.name == "Bible (Lower Third)" })
    #expect(lower.objects.map(\.name) == ["Series Art", "Scrim", "Verse", "Reference"])
}

// MARK: Claude's answer

@Test func claudeLeavingOutTheBackgroundAndBarStillBuildsEveryDesign() throws {
    // Only some fields came back: everything else is the palette's read.
    let fallback = ArtAnalysis.local(swatches: [.init(color: hex("#14213D"), share: 1)], seriesTitle: "")
    let partial = ##"{"seriesTitle": "Rooted", "accentColor": "#FCA311", "headingAllCaps": false}"##
    let read = try ArtAnalysis.decode(partial, filling: fallback)
    #expect(read.seriesTitle == "Rooted" && read.accentColor == "#FCA311" && !read.headingAllCaps)
    #expect(read.textBackground == fallback.textBackground && read.lowerThird == fallback.lowerThird)

    let navy = [hex("#14213D")]
    let theme = PhotoSeriesTheme.make(input(read.sanitized(installedFamilies: families), background: navy, title: navy))
    #expect(theme.slides?.count == 9)
    expectReadable(theme, background: navy, title: navy)
}

@Test func aMalformedAnswerFallsBackToTheLocalRead() throws {
    let fallback = ArtAnalysis.local(swatches: [.init(color: hex("#F4EEDF"), share: 1)], seriesTitle: "")
    #expect(throws: ArtAnalysis.NotAnObject.self) { try ArtAnalysis.decode("I can't help with that.", filling: fallback) }
    #expect(throws: ArtAnalysis.NotAnObject.self) { try ArtAnalysis.decode(#"["not", "an", "object"]"#, filling: fallback) }

    // Wrong kinds of value are dropped one by one; the rest is kept.
    let mangled = """
    {"seriesTitle": "Rooted", "textColor": 12, "focusX": "middle", "textBackground": {"kind": "sparkly", "tone": "light"},
     "lowerThird": {"opacity": null, "color": "#223344"}, "headingWeight": "ultra"}
    """
    let read = try ArtAnalysis.decode(mangled, filling: fallback)
    #expect(read.seriesTitle == "Rooted")
    #expect(read.textColor == fallback.textColor && read.focusX == fallback.focusX)
    #expect(read.textBackground.kind == fallback.textBackground.kind && read.textBackground.tone == .light)
    #expect(read.lowerThird.opacity == fallback.lowerThird.opacity && read.lowerThird.color == "#223344")
    #expect(read.headingWeight == fallback.headingWeight)

    let cream = [hex("#F4EEDF")]
    let theme = PhotoSeriesTheme.make(input(fallback.sanitized(installedFamilies: families), background: cream, title: cream))
    expectReadable(theme, background: cream, title: cream)
}

// MARK: Themes already made

@Test func aDesignMissingItsTextGetsItBack() throws {
    var theme = SermonSeriesTheme.make(SermonSeriesStyle(name: "Rooted", backgroundMediaID: "art", textColor: "#111111FF"))
    let index = try #require(theme.slides?.firstIndex { $0.name == SermonSeriesTheme.scriptureCategory })
    theme.slides?[index].objects.removeAll { $0.objectKind == .text }
    let fixed = SermonSeriesTheme.completed(theme)
    let bible = try #require(fixed.slides?[index])
    #expect(bible.objects.map(\.name) == ["Series Art", "Verse", "Reference"])
    #expect(bible.objects.last?.textStyle?.colorHex == "#111111FF", "in the theme's text color")
    #expect(SermonSeriesTheme.completed(fixed) == fixed, "nothing more to add")
}

@Test func seriesSavedWithTextUnderTheArtArePutRight() throws {
    // How every series was saved before: text first, art and bar after it.
    let current = SermonSeriesTheme.make(SermonSeriesStyle(name: "Rooted", backgroundMediaID: "art"))
    var saved = current
    saved.slides = current.slides?.map { design in
        var design = design
        design.objects = design.objects.filter { $0.objectKind == .text } + design.objects.filter { $0.objectKind != .text }
        return design
    }
    let fixed = try #require(SermonSeriesTheme.relayered(saved))
    #expect(fixed == current)
    #expect(SermonSeriesTheme.relayered(fixed) == nil, "running it again changes nothing")
    #expect(SermonSeriesTheme.relayered(current) == nil)

    // A bar's trim ends up on the bar.
    let trimmed = [
        SlideObject(id: "t", objectKind: .text, name: "Verse", text: ""),
        SlideObject(id: "r", objectKind: .shape, name: "Accent Rule", text: ""),
        SlideObject(id: "b", objectKind: .shape, name: "Bar", text: ""),
    ]
    #expect(SermonSeriesTheme.layered(trimmed).map(\.id) == ["b", "r", "t"])
}

@Test func theBuiltInLowerThirdsDrawTheirBarFirst() {
    for theme in [BasicTemplates.worship(), BasicTemplates.scripture(), BasicTemplates.points()] {
        for design in theme.slides ?? [] where SermonSeriesTheme.isLowerThird(design) {
            #expect(design.objects.first?.name == "Bar", "\(design.name)")
        }
        #expect(SermonSeriesTheme.relayered(theme) == nil)
    }
}
