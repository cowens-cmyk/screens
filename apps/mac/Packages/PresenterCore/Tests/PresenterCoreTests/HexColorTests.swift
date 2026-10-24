import Foundation
import Testing
@testable import PresenterCore

@Test func hexColorReadsWhatPeopleTypeAndPaste() throws {
    let navy = try #require(HexColor("#1E2A44"))
    #expect(navy.stored == "#1E2A44FF")
    #expect(HexColor("1e2a44") == navy, "no #, lowercase")
    #expect(HexColor("  #1E2A44\n") == navy, "pasted with whitespace")
    #expect(HexColor("\"#1E2A44\";") == navy, "copied out of a stylesheet")
    #expect(HexColor("0x1E2A44") == navy)
    #expect(HexColor("#FFF")?.stored == "#FFFFFFFF", "three digits double up")
    #expect(HexColor("f80")?.stored == "#FF8800FF")
    let veil = try #require(HexColor("#00000080"))
    #expect(abs(veil.alpha - 128.0 / 255) < 0.0001)
    #expect(veil.stored == "#00000080")
}

@Test func hexColorRejectsWhatIsntAColor() {
    for text in ["", "#", "blue", "#12", "#1234", "#12345", "#1234567", "#123456789", "#GG0000", "# 123456", "##123456"] {
        #expect(HexColor(text) == nil, "\(text)")
    }
    #expect(HexColor.normalized("nope") == nil)
    #expect(HexColor.normalized("#abc") == "#AABBCCFF")
}

@Test func hexColorShowsAlphaOnlyWhenItMatters() throws {
    let gold = try #require(HexColor("#FFB21EFF"))
    #expect(gold.display() == "#FFB21E", "opaque shows six digits")
    let tint = try #require(HexColor("#FFB21E80"))
    #expect(tint.display() == "#FFB21E80")
    #expect(tint.display(allowsAlpha: false) == "#FFB21E", "a field without opacity never shows it")
    #expect(tint.opaque.stored == "#FFB21EFF")
}

/// Every color control takes a hex code, so a color can be matched
/// exactly: the system color well appears only inside HexColorField.
@Test func everyColorControlHasAHexField() throws {
    let sweep = try SourceSweep.app()
    var bare: [String] = []
    for file in sweep.files where file.name != "HexColorField.swift" {
        for index in file.codeLines.indices where file.code(index).contains("ColorPicker(") {
            bare.append("\(file.name):\(index + 1)")
        }
    }
    #expect(bare.isEmpty, "use HexColorField instead of a bare ColorPicker: \(bare)")
    #expect(try #require(sweep.file("HexColorField.swift")).text.contains("ColorPicker("))
}

@Test func hexColorRoundTripsAndClamps() {
    let color = HexColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
    #expect(HexColor(color.stored) == HexColor(red: 51 / 255, green: 102 / 255, blue: 153 / 255, alpha: 128 / 255))
    #expect(HexColor(red: 2, green: -1, blue: .nan).stored == "#FF0000FF")
    // The series code reads hex through the same parser.
    #expect(SeriesColor(hex: "#FFF") == .white)
    #expect(SeriesDesign.color("#0af", fallback: "#000000FF") == "#00AAFFFF")
}
