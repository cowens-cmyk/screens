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
        Canvas { context, size in
            let firstColumn = Int((phase.x / square).rounded(.down))
            let firstRow = Int((phase.y / square).rounded(.down))
            let lastColumn = Int(((phase.x + size.width) / square).rounded(.up))
            let lastRow = Int(((phase.y + size.height) / square).rounded(.up))
            let squareInk = dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.07)
            for row in firstRow ..< max(lastRow, firstRow) {
                for column in firstColumn ..< max(lastColumn, firstColumn) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * square - phase.x, y: CGFloat(row) * square - phase.y,
                            width: square, height: square
                        )),
                        with: .color(squareInk)
                    )
                }
            }
        }
        .background(dark ? Color.black.opacity(0.45) : Color.primary.opacity(0.025))
        .allowsHitTesting(false)
    }
}
