import Foundation
import Testing
@testable import PresenterCore

// MARK: What's taken where

@Test func aPlanTakesOnlyOnePictureOrOneZip() {
    for name in ["art.jpg", "Art.JPEG", "series.png", "photo.heic", "scan.tiff", "art.webp", "download.zip"] {
        #expect(DesignDownload.acceptsOnPlan([name]), "\(name)")
    }
    for names in [["notes.pdf"], ["art.svg"], ["screens-theme.json"], ["Series Folder"], ["a.jpg", "b.jpg"], []] {
        #expect(!DesignDownload.acceptsOnPlan(names), "\(names)")
    }
    #expect(DesignDownload.isPDF("Sermon Notes.PDF") && !DesignDownload.isPDF("art.png"))
}

// MARK: Download limits

@Test func aDownloadStaysInsideItsFolder() {
    #expect(DesignDownload.isInside("/tmp/claude-design-1/zip-0/bg.png", root: "/tmp/claude-design-1/zip-0"))
    #expect(DesignDownload.isInside("/tmp/a", root: "/tmp/a/"))
    #expect(!DesignDownload.isInside("/tmp/ab/c.png", root: "/tmp/a"), "a sibling with a longer name is outside")
    #expect(!DesignDownload.isInside("/Users/me/Documents/taxes.pdf", root: "/tmp/a"))
    #expect(DesignDownload.depth(of: "/r/bg.png", under: "/r") == 0)
    #expect(DesignDownload.depth(of: "/r/a/b/bg.png", under: "/r") == 2)
    #expect(DesignDownload.depth(of: "/elsewhere/bg.png", under: "/r") == nil)
}

@Test func aZipIsCheckedBeforeItsUnpacked() throws {
    try DesignDownload.checkEntries("Rooted/\nRooted/background.png\nRooted/lower-third.svg\n__MACOSX/._x\n")
    for bad in ["../escape.png", "Rooted/../../escape.png", "/etc/hosts", "a\\..\\b.png"] {
        #expect(throws: DesignDownload.LimitError.unreadableZip) { try DesignDownload.checkEntries("ok.png\n\(bad)") }
    }
    let many = (0...DesignDownload.maxFiles).map { "f\($0).png" }.joined(separator: "\n")
    #expect(throws: DesignDownload.LimitError.tooManyFiles) { try DesignDownload.checkEntries(many) }

    let listing = """
    Archive:  rooted.zip
      Length      Date    Time    Name
    ---------  ---------- -----   ----
      2457600  10-23-2026 21:00   Rooted/background.png
       812000  10-23-2026 21:00   Rooted/lower-third.png
    ---------                     -------
      3269600                     2 files
    """
    #expect(DesignDownload.listedSize(listing) == 3_269_600)
    #expect(DesignDownload.listedSize("caution: zipfile comment truncated") == nil)
}

@Test func aDownloadsFilesAreCountedAgainstTheLimits() throws {
    var tally = DesignDownload.Tally()
    for _ in 0..<DesignDownload.maxFiles { try tally.add(bytes: 1000, depth: 1) }
    #expect(throws: DesignDownload.LimitError.tooManyFiles) { try tally.add(bytes: 1, depth: 0) }

    var big = DesignDownload.Tally()
    try big.add(bytes: DesignDownload.maxBytes - 10, depth: 0)
    #expect(throws: DesignDownload.LimitError.tooLarge) { try big.add(bytes: 11, depth: 0) }

    var deep = DesignDownload.Tally()
    try deep.add(bytes: 1, depth: DesignDownload.maxDepth)
    #expect(throws: DesignDownload.LimitError.tooDeep) { try deep.add(bytes: 1, depth: DesignDownload.maxDepth + 1) }
    #expect(DesignDownload.LimitError.tooLarge.errorDescription == "That download is over 200 MB.")
}

// MARK: SVG

private let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

@Test func aDownloadsSVGKeepsItsEmbeddedPictureButNothingElseOutside() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1920 1080">
    <defs><linearGradient id="g"><stop offset="0"/></linearGradient></defs>
    <image width="1920" height="1080" xlink:href="data:image/png;base64,\(pixel)"/>
    <image href="https://example.com/tracker.png" width="1" height="1"></image>
    <image href='file:///Users/me/secret.png'/>
    <use href="#g"/><use xlink:href="other.svg#shape"/>
    <rect fill="url(#g)" width="10" height="10"/><rect style="fill:url(https://example.com/x.svg#p)"/>
    <style>@import url("https://example.com/font.css");</style>
    <script>alert(1)</script><foreignObject><div>hi</div></foreignObject>
    <text x="1">Rooted</text>
    </svg>
    """
    let kept = SeriesDesign.sanitize(svg, keepEmbeddedImages: true)
    #expect(kept.contains("data:image/png;base64,\(pixel)"), "the embedded picture stays")
    #expect(!kept.contains("example.com") && !kept.contains("file:///") && !kept.contains("other.svg"))
    #expect(kept.contains(##"href="#g""##) && kept.contains("url(#g)"), "references within the file stay")
    #expect(!kept.contains("<script") && !kept.contains("<foreignObject") && !kept.contains("<text"))
    #expect(!kept.contains("</image>"))

    // Claude's own drawings never carry pictures.
    let claude = SeriesDesign.sanitize(svg)
    #expect(!claude.contains("<image") && !claude.contains("data:image"))
}

@Test func anSVGsShapeComesFromItsViewBox() {
    #expect(SeriesDesign.svgSize(#"<svg viewBox="0 0 1920 1080" width="100%">"#).map { $0.width == 1920 && $0.height == 1080 } == true)
    #expect(SeriesDesign.svgSize(#"<svg viewBox='0,0,1000,200'>"#).map { $0.width == 1000 && $0.height == 200 } == true)
    #expect(SeriesDesign.svgSize(#"<svg stroke-width="3" width="800px" height="600px">"#).map { $0.width == 800 && $0.height == 600 } == true)
    #expect(SeriesDesign.svgSize(#"<svg width="100%" height="100%">"#) == nil)
    #expect(SeriesDesign.svgSize("not an svg") == nil)
}

@Test func anSVGsEmbeddedPicturesCanBeReadOut() throws {
    let svg = #"<svg><image xlink:href="data:image/png;base64,\#(pixel)"/><image href="https://x/y.png"/></svg>"#
    let images = SeriesDesign.embeddedImages(svg)
    #expect(images.count == 1)
    let data = try #require(images.first)
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a PNG")
}

// MARK: Drawing and the bar

@Test func artworkIsDrawnAtItsOwnShape() {
    func size(_ width: Double, _ height: Double) -> [Int] {
        let size = ArtCrop.renderSize(width: width, height: height)
        return [size.width, size.height]
    }
    #expect(size(1920, 1080) == [1920, 1080])
    #expect(size(960, 540) == [1920, 1080])
    #expect(size(800, 800) == [1920, 1920], "covers the slide; cropped later like any picture")
    #expect(size(1000, 200) == [3840, 768], "no more than 3840 on a side")

    func fit(_ width: Double, _ height: Double) -> [Double] {
        let rect = ArtCrop.bottomFit(width: width, height: height)
        return [rect.x, rect.y, rect.width, rect.height]
    }
    #expect(fit(1920, 400) == [0, 680, 1920, 400], "a strip rests on the bottom edge")
    #expect(fit(1000, 1000) == [420, 0, 1080, 1080], "fitted, never stretched")
    #expect(fit(3840, 2160) == [0, 0, 1920, 1080])
}

@Test func aSeeThroughBarIsMeasuredOverDarkAndLightShots() {
    let navy = SeriesColor(hex: "#14213D")!
    let samples = PhotoSeriesTheme.barSamples([(navy, 0.75), (navy, 0.3), (navy, 1), (.white, 0)])
    #expect(samples.count == 3, "clear and faint pixels are the camera shot; a 75% one is laid over black and white")
    #expect(samples[0] == navy.composited(alpha: 0.75, over: .black))
    #expect(samples[1] == navy.composited(alpha: 0.75, over: .white))
    #expect(samples[2] == navy)
}

@Test func aDownloadsBarKeepsItsOwnTextColorWhenItReads() {
    let navy = SeriesColor(hex: "#14213D")!
    let gold = SeriesColor(hex: "#F2C14E")!
    let analysis = ArtAnalysis.local(swatches: SeriesPalette.extract([navy, gold], count: 2), seriesTitle: "", variant: 0)
    var bar = analysis
    bar.lowerThird.textColor = gold.hex()
    var made = PhotoSeriesTheme.Input(
        name: "Rooted", analysis: bar, headingFont: "HelveticaNeue-Bold", bodyFont: "HelveticaNeue",
        verseFont: "HelveticaNeue", titleArtMediaID: "art", artWidth: 1920, artHeight: 1080,
        textBackgroundMediaID: nil, lowerThirdMediaID: "bar-art")
    // A solid navy bar with clear camera shot above it, inside the text
    // area: the clear pixels aren't what the gold text sits on.
    let pixels = Array(repeating: (color: SeriesColor.black, alpha: 0.0), count: 40)
        + Array(repeating: (color: navy, alpha: 1.0), count: 60)
    made.lowerThirdSamples = PhotoSeriesTheme.barSamples(pixels)
    #expect(made.lowerThirdSamples.count == 60, "only the bar is measured")
    #expect(PhotoSeriesTheme.colors(for: made).barText.hex() == gold.hex(), "the download's gold is kept")

    // Gold that can't read on a pale bar still gives way.
    made.lowerThirdSamples = PhotoSeriesTheme.barSamples([(SeriesColor(hex: "#F4EEDC")!, 1)])
    let pale = PhotoSeriesTheme.colors(for: made).barText
    #expect(pale.hex() != gold.hex())
    #expect(SeriesContrast.worst(pale, on: made.lowerThirdSamples) >= 4.4, "rounding the color to a byte costs a hair")

    // Nothing solid where the text sits: it's over the camera itself.
    made.lowerThirdSamples = PhotoSeriesTheme.barSamples(Array(pixels.prefix(40)))
    #expect(made.lowerThirdSamples.isEmpty)
    let bare = PhotoSeriesTheme.colors(for: made).barText
    #expect(bare == .white || bare == .black)
}
