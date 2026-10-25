import Foundation
import Testing
@testable import PresenterCore

// MARK: Palette

@Test func paletteFindsTheArtsMainColors() {
    let navy = SeriesColor(red: 0.05, green: 0.1, blue: 0.25)
    let gold = SeriesColor(red: 0.95, green: 0.7, blue: 0.15)
    let cream = SeriesColor(red: 0.96, green: 0.93, blue: 0.86)
    // 60% navy, 30% cream, 10% gold, with a little noise.
    var pixels: [SeriesColor] = []
    for index in 0..<1000 {
        let jitter = Double(index % 7) * 0.004
        let base = index < 600 ? navy : index < 900 ? cream : gold
        pixels.append(SeriesColor(red: base.red + jitter, green: base.green + jitter, blue: base.blue - jitter))
    }
    let swatches = SeriesPalette.extract(pixels, count: 5)
    #expect(swatches.count >= 3)
    #expect(swatches[0].color.distanceSquared(to: navy) < 0.01)
    #expect(abs(swatches[0].share - 0.6) < 0.02)
    #expect(abs(swatches.map(\.share).reduce(0, +) - 1) < 0.0001)
    // Gold is the accent: the most vivid color that isn't a speck.
    #expect(SeriesPalette.accent(of: swatches)?.distanceSquared(to: gold) ?? 1 < 0.01)
    // The same pixels always give the same palette.
    #expect(SeriesPalette.extract(pixels, count: 5) == swatches)
}

@Test func paletteHandlesFlatAndEmptyImages() {
    #expect(SeriesPalette.extract([]).isEmpty)
    let flat = [SeriesColor](repeating: SeriesColor(red: 0.2, green: 0.3, blue: 0.4), count: 50)
    let swatches = SeriesPalette.extract(flat, count: 6)
    #expect(swatches.count == 1)
    #expect(swatches[0].share == 1)
}

// MARK: Contrast

@Test func contrastMatchesWCAG() {
    #expect(abs(SeriesColor.white.contrast(with: .black) - 21) < 0.001)
    #expect(abs(SeriesColor.white.contrast(with: .white) - 1) < 0.001)
    // #767676 on white is the classic 4.54:1.
    let grey = SeriesColor(hex: "#767676")!
    #expect(abs(grey.contrast(with: .white) - 4.54) < 0.01)
    #expect(SeriesColor(hex: "#12345678")?.hex() == "#123456FF")
    #expect(SeriesColor(hex: "blue") == nil)
}

@Test func lowContrastTextIsFixedAndGoodTextIsLeftAlone() {
    let navy = SeriesColor(hex: "#14213D")!
    let gold = SeriesColor(hex: "#FCA311")!
    #expect(SeriesContrast.readable(gold, on: [navy]) == gold, "gold already reads on navy")

    // Mid grey on a mid grey background is lifted until it passes, and
    // keeps its hue: still more red than blue.
    let dull = SeriesColor(hex: "#8A6F6A")!
    let background = SeriesColor(hex: "#6B6B6B")!
    let fixed = SeriesContrast.readable(dull, on: [background])
    #expect(fixed.contrast(with: background) >= SeriesContrast.minimum)
    #expect(fixed.red > fixed.blue)

    // Against light and dark samples at once, the worst one counts.
    let samples = [SeriesColor(hex: "#202020")!, SeriesColor(hex: "#505050")!]
    #expect(SeriesContrast.worst(SeriesContrast.readable(.white.mixed(with: .black, amount: 0.5), on: samples),
                                 on: samples) >= SeriesContrast.minimum)
}

@Test func lowerThirdTextReadsOverAnyCameraShot() {
    // A pale see-through bar: no text color passes over both a black and a
    // white shot, so the bar is made more solid until one does.
    let pale = SeriesColor(hex: "#7A8CA3")!
    let fixed = PhotoSeriesTheme.barText(bar: pale, opacity: 0.4, text: .white, accent: SeriesColor(hex: "#FFD166")!)
    let backdrops = [pale.composited(alpha: fixed.opacity, over: .black), pale.composited(alpha: fixed.opacity, over: .white)]
    #expect(fixed.opacity > 0.4)
    #expect(SeriesContrast.worst(fixed.text, on: backdrops) >= SeriesContrast.minimum)
    #expect(SeriesContrast.worst(fixed.accent, on: backdrops) >= SeriesContrast.minimum
            || fixed.opacity == 1, "the accent is fixed as far as the bar allows")

    // A deep, nearly solid bar with white text is left alone.
    let navy = SeriesColor(hex: "#0B1A33")!
    let solid = PhotoSeriesTheme.barText(bar: navy, opacity: 0.9, text: .white, accent: .white)
    #expect(solid.opacity == 0.9 && solid.text == .white)
}

// MARK: Analysis

private let analysisJSON = """
{
  "seriesTitle": "  Rooted  ",
  "artHasTitle": true,
  "rationale": "Earthy greens from the art.",
  "palette": ["#1F3B2D", "#E8DCC4", "#C77D2E", "not a color"],
  "accentColor": "#C77D2E",
  "textColor": "#FFFFFF",
  "focusX": 0.4,
  "focusY": 1.7,
  "titleUsesArt": true,
  "titleZone": {"x": 0.05, "y": 0.7, "width": 0.9, "height": 0.25},
  "textBackground": {"kind": "gradient", "tone": "dark", "strength": 3, "blur": -1, "colors": ["#1F3B2D"]},
  "headingFont": "Gotham Ultra",
  "headingWeight": "black",
  "bodyFont": "avenir next",
  "headingAllCaps": true,
  "scriptureItalic": true,
  "lowerThird": {"style": "glass", "color": "nope", "opacity": 0.1, "placement": "floating",
                 "accentRule": true, "textColor": "#FFFFFF", "accentColor": "#C77D2E"}
}
"""

@Test func analysisDecodesAndIsSanitized() throws {
    let raw = try ArtAnalysis.decode(analysisJSON)
    #expect(raw.textBackground.kind == .gradient)
    #expect(raw.lowerThird.placement == .floating)
    #expect(raw.headingWeight == .black)

    let clean = raw.sanitized(installedFamilies: ["Helvetica Neue", "Avenir Next", "Georgia"])
    #expect(clean.seriesTitle == "Rooted")
    #expect(clean.headingFont == "Helvetica Neue", "a font that isn't installed falls back")
    #expect(clean.bodyFont == "Avenir Next", "matched regardless of case, spelled as installed")
    #expect(clean.palette == ["#1F3B2DFF", "#E8DCC4FF", "#C77D2EFF"], "bad colors are dropped")
    #expect(clean.focusY == 1 && clean.focusX == 0.4)
    #expect(clean.textBackground.strength == 1 && clean.textBackground.blur == 0)
    #expect(clean.textBackground.colors.count == 2, "a one-color gradient gets a second stop")
    #expect(clean.lowerThird.color == "#1F3B2DFF", "a bad bar color becomes the deepest palette color")
    #expect(clean.lowerThird.opacity == 0.35)
    #expect(clean.titleZone == raw.titleZone)

    // A sliver of a zone isn't kept.
    var thin = raw
    thin.titleZone = .init(x: 0.1, y: 0.1, width: 0.05, height: 0.9)
    #expect(thin.sanitized(installedFamilies: ["Georgia"]).titleZone.isEmpty)
    #expect(thin.sanitized(installedFamilies: ["Georgia"]).headingFont == "Georgia",
            "with no Helvetica Neue, the first installed family")
}

@Test func theSchemaAsksForEveryField() throws {
    let schema = ArtAnalysis.schema
    let required = try #require(schema["required"] as? [String])
    let properties = try #require(schema["properties"] as? [String: Any])
    #expect(Set(required) == Set(properties.keys))
    #expect(schema["additionalProperties"] as? Bool == false)
    // Every field in the schema is one the decoder reads.
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ArtAnalysis.decode(analysisJSON))) as? [String: Any]
    #expect(Set(encoded.map { Array($0.keys) } ?? []) == Set(properties.keys))
    let bar = try #require((properties["lowerThird"] as? [String: Any])?["properties"] as? [String: Any])
    #expect((bar["style"] as? [String: Any])?["enum"] as? [String] == ["solid", "gradient", "glass"])
    #expect(ArtAnalysis.prompt(fileName: "rooted.jpg", width: 1600, height: 900, fonts: ["Georgia", "Futura"])
        .contains("Georgia, Futura"))
}

@Test func artIsCroppedAroundItsFocus() {
    // A square image fills 16:9 by losing top and bottom.
    let square = ArtCrop.visible(imageWidth: 1000, imageHeight: 1000, focusX: 0.5, focusY: 0)
    #expect(square.width == 1 && abs(square.height - 0.5625) < 0.0001 && square.y == 0)
    let low = ArtCrop.visible(imageWidth: 1000, imageHeight: 1000, focusX: 0.5, focusY: 1)
    #expect(abs(low.y - 0.4375) < 0.0001)
    // A zone in the bottom band of the image, seen through the top crop,
    // is gone; seen through the bottom crop it's on the slide.
    let zone = ArtAnalysis.Zone(x: 0.1, y: 0.85, width: 0.8, height: 0.12)
    #expect(ArtCrop.slideRect(of: zone, visible: square) == nil)
    let rect = ArtCrop.slideRect(of: zone, visible: low)
    #expect(rect.map { abs($0.x - 192) < 0.01 && abs($0.width - 1536) < 0.01 } == true)
}

@Test func localAnalysisNeedsNoClaude() {
    let swatches = [
        SeriesPalette.Swatch(color: SeriesColor(hex: "#101828")!, share: 0.7),
        SeriesPalette.Swatch(color: SeriesColor(hex: "#E63946")!, share: 0.2),
        SeriesPalette.Swatch(color: SeriesColor(hex: "#F1FAEE")!, share: 0.1),
    ]
    let local = ArtAnalysis.local(swatches: swatches, seriesTitle: "Advent")
    #expect(local.textBackground.kind == .blurredArt && local.textBackground.tone == .dark)
    #expect(local.textColor == "#FFFFFFFF")
    #expect(local.accentColor == "#E63946FF")
    #expect(local.seriesTitle == "Advent")
    #expect(SeriesColor(hex: local.lowerThird.color)!.luminance < 0.2)
    #expect(local.sanitized(installedFamilies: ["Avenir Next"]) == local.sanitized(installedFamilies: ["Avenir Next"]))

    // Light art is washed out behind dark text.
    let light = ArtAnalysis.local(swatches: [.init(color: SeriesColor(hex: "#F4F1EA")!, share: 1)], seriesTitle: "")
    #expect(light.textBackground.tone == .light)
    #expect(SeriesColor(hex: light.textColor)!.luminance < 0.1)
}

// MARK: Theme

private func firstText(_ design: Slide) -> SlideObject? {
    design.objects.first { $0.objectKind == .text }
}

private func input(_ analysis: ArtAnalysis, blurred: Bool = false) -> PhotoSeriesTheme.Input {
    var analysis = analysis.sanitized(installedFamilies: ["Helvetica Neue", "Avenir Next"])
    if blurred { analysis.textBackground = .init(kind: .blurredArt, tone: .dark, strength: 0.7, blur: 0.7, colors: []) }
    return PhotoSeriesTheme.Input(
        name: "Rooted", analysis: analysis, headingFont: "HelveticaNeue-Bold", bodyFont: "AvenirNext-Regular",
        verseFont: "AvenirNext-Italic", titleArtMediaID: "art", artWidth: 1920, artHeight: 1080,
        textBackgroundMediaID: blurred ? "soft" : nil,
        textBackgroundSamples: blurred ? [SeriesColor(hex: "#2A2A2A")!, SeriesColor(hex: "#3A3530")!] : [],
        titleSamples: [SeriesColor(hex: "#203020")!])
}

@Test func aPhotoBecomesAWholeSeries() throws {
    let theme = PhotoSeriesTheme.make(input(try ArtAnalysis.decode(analysisJSON), blurred: true))
    let slides = theme.slides ?? []
    #expect(theme.isSermonSeries == true && theme.name == "Rooted")
    #expect(slides.count == 9, "five full-screen designs and four lower thirds")
    #expect(SermonSeriesTheme.isSeries(theme))
    for category in [SermonSeriesTheme.pointCategory, SermonSeriesTheme.scriptureCategory,
                     SermonSeriesTheme.pointScriptureCategory, SermonSeriesTheme.worshipCategory] {
        let route = theme.streamDesigns?.first { $0.category == category }
        #expect(route?.mode == .design, "\(category)")
        let lower = slides.first { $0.id == route?.slideId }
        #expect(lower?.folder == BasicTemplates.lowerThirds, "\(category)")
        #expect(lower?.objects.contains { $0.name == "Bar" } == true, "\(category)")
        // Every design keeps the text boxes the sermon import fills.
        let design = try #require(slides.first { $0.name == category && $0.folder == nil })
        #expect(design.objects.first?.fill?.mediaId == "soft", "\(category) sits on the blurred art")
        #expect(design.objects.last?.objectKind == .text, "\(category) text is drawn over it")
    }
    #expect(theme.streamDesigns?.first { $0.category == SermonSeriesTheme.titleCategory }?.mode == .clear)
    #expect(SermonSeriesTheme.upgraded(theme) == nil, "nothing left to add")

    // The Title slide is the art itself, with the message title (not the
    // series title, which the art already carries) in the calm zone.
    let title = try #require(slides.first { $0.name == SermonSeriesTheme.titleCategory })
    #expect(title.objects.first?.fill?.mediaId == "art")
    #expect(title.objects.map(\.name).suffix(2) == ["Title", "Subtitle"])
    let titleBox = try #require(title.objects.first { $0.name == "Title" })
    #expect((titleBox.y ?? 0) >= 1080 * 0.7 - 1, "in the zone at the bottom of the art")
    #expect((titleBox.textStyle?.fontSize ?? 0) <= 72, "a caption to the art, not a second title")

    // Text reads on what it sits on.
    let point = try #require(slides.first { $0.name == SermonSeriesTheme.pointCategory })
    let text = try #require(SeriesColor(hex: firstText(point)?.textStyle?.colorHex ?? ""))
    #expect(SeriesContrast.worst(text, on: [SeriesColor(hex: "#2A2A2A")!, SeriesColor(hex: "#3A3530")!]) >= 4.5)
    #expect(firstText(point)?.textStyle?.fontName == "HelveticaNeue-Bold")
    let scripture = try #require(slides.first { $0.name == SermonSeriesTheme.scriptureCategory })
    #expect(firstText(scripture)?.textStyle?.fontName == "AvenirNext-Italic")
}

@Test func flatArtGetsAGradientBackgroundAndAFloatingGlassBar() throws {
    let theme = PhotoSeriesTheme.make(input(try ArtAnalysis.decode(analysisJSON)))
    let slides = theme.slides ?? []
    let point = try #require(slides.first { $0.name == SermonSeriesTheme.pointCategory })
    let background = try #require(point.objects.first)
    #expect(background.fill?.fillKind == .linearGradient)
    #expect(background.fill?.gradientStops?.count == 2)
    let worship = try #require(slides.first { $0.name == SermonSeriesTheme.worshipCategory && $0.folder == nil })
    #expect(worship.objects.first?.fill?.fillKind == .linearGradient)

    let lower = try #require(slides.first { $0.name == "\(SermonSeriesTheme.pointCategory) (Lower Third)" })
    let bar = try #require(lower.objects.first { $0.name == "Bar" })
    #expect(bar.shapeKind == .roundedRectangle, "floating")
    #expect(lower.objects.contains { $0.name == "Accent Rule" })
    #expect((firstText(lower)?.x ?? 0) > 80, "text pulled in from the inset bar's edge")
    // The pale glass bar was made solid enough for its text.
    let barColor = try #require(SeriesColor(hex: bar.fill?.colorHex ?? ""))
    let alpha = Double(Int(bar.fill?.colorHex?.suffix(2) ?? "", radix: 16) ?? 0) / 255
    let textColor = try #require(SeriesColor(hex: firstText(lower)?.textStyle?.colorHex ?? ""))
    let backdrops = [barColor.composited(alpha: alpha, over: .black), barColor.composited(alpha: alpha, over: .white)]
    #expect(SeriesContrast.worst(textColor, on: backdrops) >= 4.4, "rounding the alpha to a byte costs a hair")
}

@Test func adjustedColorsAreUsedAsPicked() throws {
    var made = input(try ArtAnalysis.decode(analysisJSON), blurred: true)
    let pink = SeriesColor(hex: "#FF66CC")!
    made.textColorOverride = pink
    made.accentColorOverride = SeriesColor(hex: "#00FFAA")!
    made.barColorOverride = SeriesColor(hex: "#330022")!
    let colors = PhotoSeriesTheme.colors(for: made)
    #expect(colors.text == pink && colors.titleText == pink)
    #expect(colors.bar == SeriesColor(hex: "#330022")!)
    let slides = PhotoSeriesTheme.make(made).slides ?? []
    #expect(slides.first.flatMap(firstText)?.textStyle?.colorHex == pink.hex())
}

@Test func artThatCantBeCroppedLeavesTheTitleOnTheBackground() throws {
    var analysis = try ArtAnalysis.decode(analysisJSON)
    analysis.titleUsesArt = false
    analysis.artHasTitle = false
    let theme = PhotoSeriesTheme.make(input(analysis, blurred: true))
    let title = try #require(theme.slides?.first { $0.name == SermonSeriesTheme.titleCategory })
    #expect(title.objects.first?.fill?.mediaId == "soft")
    #expect(!(title.objects.contains { $0.fill?.mediaId == "art" }))
}

// MARK: General themes

@Test func anImageBecomesAGeneralThemeWithTheStandardCategories() throws {
    var made = input(try ArtAnalysis.decode(analysisJSON), blurred: true)
    made.kind = .general
    let theme = PhotoSeriesTheme.make(made)
    let slides = theme.slides ?? []
    #expect(theme.isSermonSeries == nil)
    #expect(!SermonSeriesTheme.isSeries(theme), "the sermon pickers and the series upgrade leave it alone")
    #expect(SermonSeriesTheme.upgraded(theme) == nil)

    let full = slides.filter { $0.folder == nil }.map(\.name)
    #expect(full == ["Lyrics", "Title", "Announcements", "Bible", "Sermon Points"])
    let lower = slides.filter { $0.folder == BasicTemplates.lowerThirds }.map(\.name)
    #expect(lower == ["Lyrics (Lower Third)", "Bible (Lower Third)", "Sermon Points (Lower Third)"])

    // Each category finds its design the way slides ask for one.
    for category in ["Lyrics", "Worship", "Announcements", "Bible", "Scripture", "Sermon Points", "Title"] {
        #expect(ThemeCategories.match(category, in: slides) != nil, "\(category)")
    }
    // Lyrics land in the Lyrics box, on the same background as the rest.
    let lyrics = try #require(slides.first)
    #expect(lyrics.objects.last?.name == "Lyrics")
    #expect(lyrics.objects.first?.fill?.mediaId == "soft")

    let announcements = try #require(slides.first { $0.name == "Announcements" })
    #expect(announcements.objects.filter { $0.objectKind == .text }.map(\.name) == ["Title", "Body"])
    #expect(announcements.objects.last?.textStyle?.fontName == "AvenirNext-Regular", "the paragraph is in the body font")
    #expect(announcements.objects.first?.fill?.mediaId == "soft")

    // Livestream routes follow the renames and each points at a design that exists.
    let routes = theme.streamDesigns ?? []
    #expect(Set(routes.map(\.category)) == ["Title", "Lyrics", "Bible", "Sermon Points"])
    for route in routes where route.mode == .design {
        #expect(slides.contains { $0.id == route.slideId }, "\(route.category)")
    }
}

// MARK: Claude Design downloads

private let designExport = SeriesExport(
    series: "Rooted", background: "background.png", lowerThird: "lower-third.png",
    headingFont: ["Gotham Black"], bodyFont: ["Gotham Book"], scriptureFont: nil, headingAllCaps: true,
    textColor: "#F5EFE0", accentColor: "#D9A441", lowerThirdTextColor: "#FFFFFF", lowerThirdAccentColor: "#D9A441")

@Test func aClaudeDesignDownloadKeepsItsOwnChoices() {
    let swatches = [
        SeriesPalette.Swatch(color: SeriesColor(hex: "#1F3B2D")!, share: 0.8),
        SeriesPalette.Swatch(color: SeriesColor(hex: "#D9A441")!, share: 0.2),
    ]
    let analysis = ArtAnalysis.designed(designExport, swatches: swatches)
    #expect(analysis.seriesTitle == "Rooted")
    #expect(analysis.textColor == "#F5EFE0FF" && analysis.accentColor == "#D9A441FF")
    #expect(!analysis.artHasTitle, "the background has no words, so the Title slide prints the title")
    #expect(analysis.textBackground.kind == .blurredArt && analysis.textBackground.tone == .dark)
    #expect(analysis.textBackground.strength == 0 && analysis.textBackground.blur == 0,
            "used as designed until the contrast check says otherwise")
    #expect(analysis.headingAllCaps)
    #expect(analysis.lowerThird.textColor == "#FFFFFFFF" && analysis.lowerThird.accentColor == "#D9A441FF")
    #expect(analysis.sanitized(installedFamilies: ["Avenir Next"]).textBackground.strength == 0)

    // Dark text on a light design keeps the background light.
    var light = designExport
    light.textColor = "#1A1A1A"
    #expect(ArtAnalysis.designed(light, swatches: swatches).textBackground.tone == .light)
}

@Test func anImageLowerThirdReplacesTheBarAndItsTextStillReads() throws {
    var made = input(try ArtAnalysis.decode(analysisJSON), blurred: true)
    made.lowerThirdMediaID = "bar-art"
    // A pale bar: white text would vanish over a bright shot.
    made.lowerThirdSamples = [SeriesColor(hex: "#B8C4D0")!, SeriesColor(hex: "#DDE3EA")!]
    let theme = PhotoSeriesTheme.make(made)
    let lower = try #require(theme.slides?.first { $0.name == "\(SermonSeriesTheme.pointCategory) (Lower Third)" })
    #expect(lower.objects.first?.fill?.mediaId == "bar-art")
    #expect(!lower.objects.contains { $0.name == "Bar" || $0.name == "Accent Rule" })
    let text = try #require(SeriesColor(hex: firstText(lower)?.textStyle?.colorHex ?? ""))
    #expect(SeriesContrast.worst(text, on: made.lowerThirdSamples) >= 4.4, "rounding the color to a byte costs a hair")
    #expect(text.luminance < 0.2, "dark text on the pale bar")
}
