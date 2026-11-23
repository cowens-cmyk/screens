import SwiftUI

struct TransparencyGrid: View {

    var square: CGFloat = 5

    /// Where this view's top-left falls within a larger checkerboard, so a
    /// zoomed editor can draw only the part of the slide in view and the
    /// squares stay put on the slide as it pans.
    var phase: CGPoint = .zero

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {

        let dark = colorScheme == .dark
        Group {
            if phase == .zero, let tile = Self.tile(square: square, dark: dark) {
                // A two-by-two tile repeated by the GPU. The Canvas below
                // was drawn on the CPU, square by square, each time a slide
                // tile came into view: a fast scroll down the booth's plan
                // spent a tenth of its main thread there (RB::Path in
                // CGDrawingLayer.draw, Nov 23).
                Image(decorative: tile, scale: Self.tileScale).resizable(resizingMode: .tile)
            } else {
                checkerCanvas(dark: dark)
            }
        }
        .background(dark ? Color.black.opacity(0.45) : Color.primary.opacity(0.025))
        .allowsHitTesting(false)
    }

    private static let tileScale: CGFloat = 2
    @MainActor private static var tiles: [String: CGImage] = [:]

    /// Two squares by two, the top-left and bottom-right inked.
    @MainActor private static func tile(square: CGFloat, dark: Bool) -> CGImage? {
        let key = "\(square)|\(dark)"
        if let tile = tiles[key] { return tile }
        let side = Int((square * tileScale).rounded())
        guard side > 0, let context = CGContext(
            data: nil, width: side * 2, height: side * 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(dark ? CGColor(gray: 1, alpha: 0.045) : CGColor(gray: 0, alpha: 0.07))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.fill(CGRect(x: side, y: side, width: side, height: side))
        let tile = context.makeImage()
        tiles[key] = tile
        return tile
    }

    private func checkerCanvas(dark: Bool) -> some View {
        Canvas { context, size in
            let firstColumn = Int((phase.x / square).rounded(.down))
            let firstRow = Int((phase.y / square).rounded(.down))
            let lastColumn = Int(((phase.x + size.width) / square).rounded(.up))
            let lastRow = Int(((phase.y + size.height) / square).rounded(.up))
            let squareInk = dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.07)
            // Every square in one path and one fill: a fill per square was
            // ~700 draws per slide tile, each drawn again whenever its tile
            // was (RB::render_primitive in the booth's hitch stacks).
            var squares = Path()
            for row in firstRow ..< max(lastRow, firstRow) {
                for column in firstColumn ..< max(lastColumn, firstColumn) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(
                        x: CGFloat(column) * square - phase.x, y: CGFloat(row) * square - phase.y,
                        width: square, height: square))
                }
            }
            context.fill(squares, with: .color(squareInk))
        }
    }
}
