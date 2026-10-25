import PresenterCore
import SwiftUI

/// Auto fits the slides to the window; dragging picks a fixed count, and
/// clicking the count goes back to Auto.
struct SlidesAcrossControl: View {
    @Binding var count: Int

    private var automatic: Bool { SlidesAcross.isAutomatic(count) }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                count = SlidesAcross.automatic
            } label: {
                Text(automatic ? "Auto" : "\(SlidesAcross.clamped(count))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(automatic ? Color.white : Color.primary)
                    .frame(width: 34, height: 20)
                    .background(
                        automatic ? Color.accentColor : Color.primary.opacity(0.08),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(automatic ? "Fitting the slides to the window" : "Go back to fitting the slides to the window")
            Slider(
                value: Binding(
                    get: { Double(automatic ? SlidesAcross.unmeasuredCount : SlidesAcross.clamped(count)) },
                    set: { raw in
                        let next = SlidesAcross.clamped(Int(raw.rounded()))
                        if next != count { count = next }
                    }
                ),
                in: Double(SlidesAcross.range.lowerBound) ... Double(SlidesAcross.range.upperBound),
                step: 1
            )
            .controlSize(.small)
        }
        .help("How many slides share a row in Present")
    }
}
