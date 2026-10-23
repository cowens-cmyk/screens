import AppKit
import CoreText
import Foundation
import PresenterCore

/// ProPresenter never clips text to its box: text taller than the box is drawn
/// past its edges, placed by the box's vertical alignment. Its lyric boxes are
/// routinely sized a point or two shy of the text they hold (a two-line Helvetica
/// box at 1.2 line height is stored 147.56 tall for text that lays out 149 tall),
/// so imported as-is they trip Screens' "text doesn't fit its box" warning on most
/// slides. The importer grows such a box to the text's height around the edge
/// ProPresenter anchors it to, which keeps the text exactly where it was.
enum ProTextFit {

    /// Grows `object` so its text fits, measured the way the renderer lays it out.
    /// Leaves shrink-to-fit boxes (the renderer scales those instead), chord charts
    /// (their extra chord rows are laid out by the renderer, not measured here),
    /// and rotated boxes not anchored at their middle alone.
    static func growToFit(_ object: inout SlideObject, scaleBehavior: RVData_Graphics.Text.ScaleBehavior) {
        switch scaleBehavior {
        case .scaleFontDown, .scaleFontUpDown: return
        default: break
        }
        guard let style = object.textStyle, style.autoShrink != true, style.showChords != true,
              style.pathData == nil,
              let y = object.y, let width = object.width, let height = object.height,
              width > 0, height > 0, !object.text.isEmpty
        else { return }
        let alignment = style.verticalAlignment ?? .middle
        if let rotation = object.rotationDegrees, rotation.truncatingRemainder(dividingBy: 360) != 0,
           alignment != .middle {
            return
        }
        let insetV = (style.insetTop ?? 0) + (style.insetBottom ?? 0)
        let layoutWidth = width - (style.insetLeft ?? 0) - (style.insetRight ?? 0)
        guard layoutWidth > 1,
              let measured = measuredHeight(object.text, style: style, runs: object.styleRuns ?? [], width: layoutWidth)
        else { return }
        // Whole points plus a hair of slack, so the renderer's own rounding of the
        // same layout never lands a fraction over the box again.
        let needed = (measured + insetV).rounded(.up) + 1
        guard needed > height else { return }
        let growth = needed - height
        object.height = needed
        switch alignment {
        case .top: break
        case .middle: object.y = y - growth / 2
        case .bottom: object.y = y - growth
        }
    }

    /// The laid-out height of `text`, built like `TextRasterizer.attributedString`:
    /// one paragraph per line with the line's font override, the box's tracking,
    /// line height multiple, indents and paragraph spacing, and per-run fonts.
    static func measuredHeight(_ text: String, style: TextStyle, runs: [TextStyleRun], width: Double) -> Double? {
        guard let baseName = style.fontName, let baseSize = style.fontSize, baseSize > 0 else { return nil }
        let fontNames = [baseName] + (style.lineStyles ?? []).compactMap(\.fontName) + runs.compactMap(\.fontName)
        guard fontNames.allSatisfy(installedFontNames.contains) else { return nil }
        let display = style.textTransform == .uppercase ? text.uppercased() : text
        let lines = display.components(separatedBy: "\n")
        let overrides = Dictionary((style.lineStyles ?? []).map { ($0.lineIndex, $0) }, uniquingKeysWith: { first, _ in first })

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let override = overrides[index]
            let name = override?.fontName ?? baseName
            let size = override?.fontSize ?? baseSize
            let left = override?.leftIndent ?? style.leftIndent ?? 0
            let first = override?.firstLineIndent ?? style.firstLineIndent ?? 0
            let right = override?.rightIndent ?? style.rightIndent ?? 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = CGFloat(style.lineHeightMultiple ?? 1)
            paragraph.firstLineHeadIndent = CGFloat(left + first)
            paragraph.headIndent = CGFloat(left)
            paragraph.tailIndent = CGFloat(-right)
            paragraph.paragraphSpacing = CGFloat(style.paragraphSpacing ?? 0)
            let segmentStart = result.length
            result.append(NSAttributedString(
                string: index == lines.count - 1 ? line : line + "\n",
                attributes: [
                    .font: font(name, size),
                    .paragraphStyle: paragraph,
                    .kern: CGFloat(override?.tracking ?? style.tracking ?? 0),
                ]
            ))
            for run in runs where run.line == index && run.length > 0 && (run.fontName != nil || run.fontSize != nil) {
                let start = min(max(0, run.column), line.count)
                let end = min(start + run.length, line.count)
                guard end > start else { continue }
                let lower = line.index(line.startIndex, offsetBy: start)
                let upper = line.index(line.startIndex, offsetBy: end)
                let range = NSRange(lower..<upper, in: line)
                result.addAttribute(
                    .font,
                    value: font(run.fontName ?? name, run.fontSize ?? size),
                    range: NSRange(location: segmentStart + range.location, length: range.length)
                )
            }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(result)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return Double(size.height)
    }

    /// A box whose font isn't installed is left as ProPresenter sized it: the
    /// fallback face measures differently from the real one, and the import already
    /// asks for a replacement. Checking the installed list first also keeps the
    /// lookup off the font service, which can stall when several import threads
    /// ask it for a missing name at once.
    private static let installedFontNames = Set(
        (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
    )

    private static func font(_ name: String, _ size: Double) -> CTFont {
        CTFontCreateWithNameAndOptions(name as CFString, CGFloat(size), nil, .preventAutoActivation)
    }
}
