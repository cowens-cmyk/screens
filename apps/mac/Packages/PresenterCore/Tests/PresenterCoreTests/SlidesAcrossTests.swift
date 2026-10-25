import Foundation
import Testing
@testable import PresenterCore

struct SlidesAcrossTests {
    @Test func rangeIsOneToEightAndTheFallbackIsAutomatic() {
        #expect(SlidesAcross.range == 1 ... 8)
        #expect(SlidesAcross.fallback == SlidesAcross.automatic)
        #expect(SlidesAcross.isAutomatic(SlidesAcross.fallback))
        #expect(!SlidesAcross.range.contains(SlidesAcross.automatic), "automatic is never a count someone chose")
        #expect(SlidesAcross.range.contains(SlidesAcross.automaticRange.lowerBound))
        #expect(SlidesAcross.range.contains(SlidesAcross.automaticRange.upperBound))
    }

    @Test func clampsToTheRange() {
        #expect(SlidesAcross.clamped(0) == 1)
        #expect(SlidesAcross.clamped(-3) == 1)
        #expect(SlidesAcross.clamped(3) == 3)
        #expect(SlidesAcross.clamped(8) == 8)
        #expect(SlidesAcross.clamped(40) == 8)
    }

    @Test func automaticFitsTilesNearTheTargetWidth() {
        #expect(SlidesAcross.fitting(width: 700, spacing: 12) == 3, "(700 − 24) / 3 = 225; 4 across would be 166")
        #expect(SlidesAcross.fitting(width: 1000, spacing: 12) == 4, "241 beats 190")
        #expect(SlidesAcross.fitting(width: 1400, spacing: 12) == 6, "(1400 − 60) / 6 = 223")
        #expect(SlidesAcross.fitting(width: 2000, spacing: 12) == 8, "239.5")
        #expect(SlidesAcross.fitting(width: 4000, spacing: 12) == 8, "never more than 8")
        #expect(SlidesAcross.fitting(width: 300, spacing: 12) == 3, "never fewer than 3")
        #expect(SlidesAcross.fitting(width: 0, spacing: 12) == 4, "not measured yet")
        for width in stride(from: CGFloat(700), through: 1900, by: 10) {
            let count = SlidesAcross.fitting(width: width, spacing: 12)
            let tile = (width - 12 * CGFloat(count - 1)) / CGFloat(count)
            #expect(tile >= 180 && tile <= 260, "\(width) pt → \(count) across, \(tile) pt tiles")
        }
    }

    @Test func aChosenCountOverridesAutomatic() {
        #expect(SlidesAcross.resolved(SlidesAcross.automatic, width: 1000, spacing: 12) == 4)
        #expect(SlidesAcross.resolved(SlidesAcross.automatic, width: 2000, spacing: 12) == 8)
        #expect(SlidesAcross.resolved(2, width: 2000, spacing: 12) == 2, "the slider wins")
        #expect(SlidesAcross.resolved(99, width: 2000, spacing: 12) == 8, "held to the range")
        #expect(SlidesAcross.resolved(-1, width: 700, spacing: 12) == 3, "anything below 1 is automatic")
    }

    @Test func everyTileGridUsesTheChosenColumnCount() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
        var grids = 0
        var violations: [String] = []
        for file in ["PresentGridView.swift", "ServiceContinuousView.swift"] {
            let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                if line.contains("LazyVGrid(columns:") {
                    grids += 1
                    if !line.contains("SlideGridMetrics.columns(across:") {
                        violations.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
                if line.contains(".adaptive(") {
                    violations.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(grids == 1, "the slide grid; the continuous view's media card is a built row (\(grids))")
        #expect(violations.isEmpty, "tile grids not on the chosen count: \(violations)")
    }

    @Test func rowsHoldTheChosenCountAndPadTheLastRow() {
        #expect(SlidesAcross.rows(count: 10, across: 4) == [
            .init(indices: 0 ..< 4, fillers: 0),
            .init(indices: 4 ..< 8, fillers: 0),
            .init(indices: 8 ..< 10, fillers: 2),
        ])
        #expect(SlidesAcross.rows(count: 1, across: 4) == [.init(indices: 0 ..< 1, fillers: 3)], "the media card's poster")
        #expect(SlidesAcross.rows(count: 0, across: 4).isEmpty)
        #expect(SlidesAcross.rows(count: 3, across: 99).first?.fillers == 5, "held to the 1…8 range")
    }

    @Test func aTileHasAnExactSizeOnceTheGridWidthIsKnown() {
        let cell = SlidesAcross.cell(width: 1000, across: 4, spacing: 12, aspect: 16 / 9, labelGap: 4, labelHeight: 14)
        #expect(cell == CGSize(width: 241, height: 136 + 4 + 14), "(1000 − 3×12) / 4 = 241; 241×9/16 = 135.6 → 136")
        #expect(SlidesAcross.cell(width: 1000, across: 4, spacing: 12, aspect: 4 / 3, labelGap: 4, labelHeight: 0)
                    == CGSize(width: 241, height: 181 + 4), "another tile shape, no strip: 241×3/4 = 180.75 → 181, plus the gap")
        #expect(SlidesAcross.cell(width: 0, across: 4, spacing: 12, aspect: 16 / 9, labelGap: 4, labelHeight: 14) == nil, "not measured yet")
        #expect(SlidesAcross.cell(width: 700, across: 99, spacing: 12, aspect: 16 / 9, labelGap: 4, labelHeight: 14)?.width == 77, "held to 8 across: (700 − 84) / 8 = 77")
    }

    @Test func aDecksTilesTakeItsCanvasShape() {
        let wide: CGFloat = 16.0 / 9.0
        let tall: CGFloat = 1080.0 / 1920.0
        let fourThree: CGFloat = 4.0 / 3.0
        #expect(SlidesAcross.tileAspect(canvas: CGSize(width: 1920, height: 1080)) == wide)
        #expect(SlidesAcross.tileAspect(canvas: CGSize(width: 1080, height: 1920)) == tall, "portrait")
        #expect(SlidesAcross.tileAspect(canvas: CGSize(width: 1024, height: 768)) == fourThree)
        #expect(SlidesAcross.tileAspect(canvas: .zero) == wide, "no usable canvas")
        let portrait = SlidesAcross.cell(width: 1000, across: 4, spacing: 12, aspect: tall, labelGap: 4, labelHeight: 14)
        #expect(portrait == CGSize(width: 241, height: 429 + 4 + 14), "241 × 16/9 = 428.4 → 429")
    }

    @Test func theSlideGridSizesEveryTileExactly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let grid = try String(contentsOf: sources.appendingPathComponent("PresentGridView.swift"), encoding: .utf8)
        #expect(grid.contains("columns: SlideGridMetrics.columns(across: slidesAcross, cellWidth: cell?.width)"))
        #expect(grid.contains(".frame(width: cell?.width, height: cell?.height, alignment: .top)"))
        #expect(grid.contains(".frame(height: SlideGridMetrics.labelHeight)"), "the label strip's height is fixed")
        #expect(grid.contains("let aspect = SlideGridMetrics.tileAspect(for: presentation)"))
        #expect(grid.contains("width: measuredWidth, across: slidesAcross, aspect: SlideGridMetrics.tileAspect(for: presentation))"))
        #expect(grid.contains("SlideGridMetrics.lastWidths[contextID] ?? (buildsRowsNearView ? SlideGridMetrics.continuousWidth : 0)"),
                "a rebuilt grid starts at its last width, and a new one at the continuous view's last width")
        #expect(grid.contains("if buildsRowsNearView { SlideGridMetrics.continuousWidth = width }"))
        let rowsFn = try #require(grid.range(of: "private func tileRows(aspect: CGFloat, cell: CGSize?) -> some View {"))
        #expect(grid[rowsFn.upperBound...].prefix(2000).contains("ForEach(0 ..< row.fillers, id: \\.self) { _ in"),
                "an unmeasured short row keeps its empty columns, so a placeholder is one column wide")
        #expect(grid.contains("PresentCardFrames.shared.noteGrid(PresentLanding.Grid("), "the grid reports where its rows sit")
        let measured = try #require(grid.range(of: ".coordinateSpace(name: \"slideGrid\")"))
        #expect(grid[measured.upperBound...].prefix(500).contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)"),
                "the width is the space offered, never the tiles' own width — or they could not shrink back")
        #expect(grid.contains(".aspectRatio(aspect, contentMode: .fit)"), "the tile draws the shape the cell is sized for")
        let surface = try String(contentsOf: sources.appendingPathComponent("ServiceContinuousView.swift"), encoding: .utf8)
        #expect(!surface.contains("LazyVGrid("), "the media card is a built row")
        #expect(surface.contains("buildsRowsNearView: true"), "the continuous view's grids are fixed rows, not a LazyVGrid")
        #expect(grid.contains("if buildsRowsNearView {\n                tileRows(aspect: aspect, cell: cell)"))
        let rows = try #require(grid.range(of: "private func tileRows(aspect: CGFloat, cell: CGSize?) -> some View {"))
        let rowBody = grid[rows.upperBound...].prefix(1200)
        #expect(!rowBody.contains("LazyVGrid"), "rows are laid out in full")
        #expect(rowBody.contains(".id(Self.tileAnchor(contextID: contextID, index: index))"), "unbuilt cells keep the pill-jump anchors")
    }

    @Test func onlyRowsNearTheViewportBuildTheirTiles() {

        #expect(SlidesAcross.nearRows(gridTop: 1000, rowPitch: 200, rowCount: 20, viewport: 900, margin: 900) == 0 ..< 5, "rows 0–4 start within a screen below the viewport")

        #expect(SlidesAcross.nearRows(gridTop: -1000, rowPitch: 200, rowCount: 20, viewport: 900, margin: 900) == 0 ..< 15)
        #expect(SlidesAcross.nearRows(gridTop: -3000, rowPitch: 200, rowCount: 20, viewport: 900, margin: 900) == 10 ..< 20)
        #expect(SlidesAcross.nearRows(gridTop: 5000, rowPitch: 200, rowCount: 20, viewport: 900, margin: 900).isEmpty, "far below")
        #expect(SlidesAcross.nearRows(gridTop: -9000, rowPitch: 200, rowCount: 20, viewport: 900, margin: 900).isEmpty, "far above")
        #expect(SlidesAcross.nearRows(gridTop: 0, rowPitch: 0, rowCount: 20, viewport: 900, margin: 900).isEmpty, "not measured")
    }
}
