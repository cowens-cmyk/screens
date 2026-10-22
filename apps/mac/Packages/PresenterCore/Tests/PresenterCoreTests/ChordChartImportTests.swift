import Foundation
import Testing
import CoreText
import CoreGraphics
@testable import PresenterCore

@Test func chordLineDetection() {
    for line in ["G C/E D", "F#m7  Bbsus4  Dmaj7", "A2 Esus N.C.", "| G | D | Em | C |", "G  D  Em  C  (x2)", "Am", "G - D - C"] {
        #expect(ChordChartImport.isChordLine(line), "\(line)")
    }
    for line in ["A mighty fortress", "Am I", "Be still", "Amazing grace", "", "VERSE 1", "Chorus", "A"] {
        #expect(!ChordChartImport.isChordLine(line), "\(line)")
    }
    #expect(ChordChartImport.isChordLine("A", nextLine: "Amazing grace"))
    #expect(!ChordChartImport.isChordLine("A", nextLine: ""))
}

@Test func mergesChordsAtExactColumns() {
    let text = "G       C\nAmazing grace how\n"
    #expect(ChordChartImport.mergeChordsOverLyrics(text) == "[G]Amazing [C]grace how")
    let slash = "G    C/E\nHow sweet the sound"
    #expect(ChordChartImport.mergeChordsOverLyrics(slash) == "[G]How s[C/E]weet the sound")
}

@Test func chordsPastEndOfLinePadLyric() {
    let text = "G         D\nOh yes"
    #expect(ChordChartImport.mergeChordsOverLyrics(text) == "[G]Oh yes    [D]")
}

@Test func instrumentalLinesAndLabels() {
    let text = """
    VERSE 1
    G        C
    Amazing grace

    Chorus:
    G D Em C (x2)

    BRIDGE (x2)
    G
    Hold on
    """
    let out = ChordChartImport.mergeChordsOverLyrics(text)
    #expect(out == "Verse 1\n[G]Amazing g[C]race\n\nChorus\n[G] [D] [Em] [C]\n\nBridge (x2)\n[G]Hold on")
}

@Test func dropsChartBreakTokens() {
    let text = "VERSE 1\nG\nHello\nCOLUMN_BREAK\nCHORUS\nC\nWorld\nPAGE_BREAK\n"
    #expect(ChordChartImport.mergeChordsOverLyrics(text) == "Verse 1\n[G]Hello\n\nChorus\n[C]World")
}

@Test func headerParsingVariants() {
    let a = ChordChartImport.header(from: [
        "Amazing Grace", "John Newton", "Key - G", "Tempo - 72", "Time - 4/4", "CCLI Song # 7106807", "", "Verse 1", "G", "Hi",
    ])
    #expect(a.0 == .init(title: "Amazing Grace", artist: "John Newton", key: "G", tempo: 72, timeSignature: "4/4", ccli: 7106807))
    #expect(a.bodyStartIndex == 7)

    let b = ChordChartImport.header(from: ["Great Are You Lord", "KEY OF Bb", "72 BPM", "CCLI # 123456", "G  D", "Hello"])
    #expect(b.0.key == "Bb" && b.0.tempo == 72 && b.0.ccli == 123456 && b.0.title == "Great Are You Lord" && b.0.artist == nil)
    #expect(b.bodyStartIndex == 4)

    let c = ChordChartImport.header(from: ["Song", "Key: F#m", "Artist: Someone", "VERSE 1"])
    #expect(c.0.key == "F#m" && c.0.artist == "Someone" && c.bodyStartIndex == 3)

    let d = ChordChartImport.header(from: ["VERSE 1", "G", "Hi"])
    #expect(d.0 == Header0 && d.bodyStartIndex == 0)
}

private let Header0 = ChordChartImport.Header()

private let sampleChart = """
Amazing Grace
John Newton
Key - G
Tempo - 72
Time - 4/4
CCLI Song # 7106807

VERSE 1
G          C        G
Amazing grace how sweet the sound
G             D
That saved a wretch like me

CHORUS
Em      D     C
My chains are gone

CCLI License # 12345
© 1779 Public Domain
"""

@Test func fullPipelineRoundTripsThroughImporter() {
    let pro = ChordChartImport.chordPro(fromChart: sampleChart)
    #expect(pro.hasPrefix("{title: Amazing Grace}\n{artist: John Newton}\n{key: G}\n{tempo: 72}\n{time: 4/4}\n{ccli: 7106807}\n\nVerse 1\n[G]Amazing gra[C]ce how sw[G]eet the sound"))
    #expect(!pro.contains("©"))
    let p = LyricTextImporter.makePresentation(pro)
    #expect(p.name == "Amazing Grace")
    #expect(p.musicKey == "G")
    #expect(p.ccli?.songNumber == 7106807)
    let names = (p.sections ?? []).map(\.name)
    #expect(names.contains("Verse 1") && names.contains("Chorus"))
    let chordObjects = p.slides.flatMap(\.objects).filter { !($0.chords ?? []).isEmpty }
    #expect(!chordObjects.isEmpty)
    let first = chordObjects[0]
    #expect(first.chords?.first?.symbol == "G" && first.chords?.first?.column == 0)
}

// MARK: PDF helpers

private func makePDF(pages: [[(x: Double, y: Double, text: String)]]) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    let black = CGColor(gray: 0, alpha: 1)
    for page in pages {
        ctx.beginPDFPage(nil)
        for item in page {
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: black]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, item.text as CFString, attrs as CFDictionary)!)
            ctx.textPosition = CGPoint(x: item.x, y: item.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

@Test func pdfRoundTripKeepsChordColumns() throws {
    let items: [(x: Double, y: Double, text: String)] = [
        (50, 740, "Amazing Grace"),
        (50, 724, "Key - G"),
        (50, 690, "VERSE 1"),
        (50, 670, "G          C"),
        (50, 656, "Amazing grace how sweet"),
        (50, 636, "Em      D"),
        (50, 622, "That saved a wretch"),
        (50, 580, "CCLI Song # 7106807"),
        (50, 40, "Page 1"),
    ]
    let url = makePDF(pages: [items])
    defer { try? FileManager.default.removeItem(at: url) }
    let pro = try #require(ChordChartImport.chordPro(fromPDF: url))
    #expect(pro.contains("{title: Amazing Grace}"))
    #expect(pro.contains("{key: G}"))
    #expect(pro.contains("{ccli: 7106807}"))
    #expect(pro.contains("[G]Amazing gra[C]ce how sweet"), "\(pro)")
    #expect(pro.contains("[Em]That sav[D]ed a wretch") , "\(pro)")
    #expect(!pro.contains("Page 1"))
}

@Test func pdfChordsLandOnExactSyllables() throws {
    let items: [(x: Double, y: Double, text: String)] = [
        (50, 700, "VERSE 1"),
        (50, 680, "G         C"),
        (50, 666, "Amazing grace how sweet"),
    ]
    let url = makePDF(pages: [items])
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try #require(ChordChartImport.text(fromPDF: url))
    #expect(text.contains("G         C\nAmazing grace how sweet"), "\(text)")
    #expect(ChordChartImport.mergeChordsOverLyrics(text).contains("[G]Amazing gr[C]ace how sweet"), "\(text)")
}

@Test func pdfTwoColumnLayoutReadsLeftThenRight() throws {
    var items: [(x: Double, y: Double, text: String)] = [(50, 750, "Two Column Song")]
    let left = ["VERSE 1", "G       C", "Left one here", "D       Em", "Left two here", "Em      D", "Left three here"]
    let right = ["CHORUS", "C       G", "Right one here", "Am      F", "Right two here", "G       D", "Right three here"]
    for (i, l) in left.enumerated() { items.append((50, 700 - Double(i) * 16, l)) }
    for (i, r) in right.enumerated() { items.append((330, 700 - Double(i) * 16, r)) }
    let url = makePDF(pages: [items])
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try #require(ChordChartImport.text(fromPDF: url))
    let lo = try #require(text.range(of: "Left three here"))
    let ro = try #require(text.range(of: "CHORUS"))
    #expect(lo.lowerBound < ro.lowerBound, "\(text)")
    #expect(text.contains("G       C\nLeft one here"), "\(text)")
    #expect(text.contains("C       G\nRight one here"), "\(text)")
    let pro = try #require(ChordChartImport.chordPro(fromPDF: url))
    #expect(pro.contains("[G]Left one[C] here"), "\(pro)")
    #expect(pro.contains("[C]Right on[G]e here"), "\(pro)")
}
