import PresenterCore
import SwiftUI

/// Lays `content` over the slide at the canvas's zoom and pan, sized to the
/// whole slide. `visible` is the part of it in view, in the content's own
/// coordinates, so controls past the edge can stand down: a clipped SwiftUI
/// view still takes clicks where it isn't drawn.
struct CanvasPlaced<Content: View>: View {
    let navigator: CanvasNavigator
    @ViewBuilder let content: (_ visible: CGRect) -> Content

    var body: some View {
        GeometryReader { proxy in
            let slide = navigator.viewport(in: proxy.size)
                .viewRect(fromCanvas: CGRect(origin: .zero, size: navigator.canvasSize))
            let visible = CGRect(origin: .zero, size: proxy.size)
                .offsetBy(dx: -slide.minX, dy: -slide.minY)
            content(visible)
                .frame(width: max(slide.width, 0), height: max(slide.height, 0))
                .position(x: slide.midX, y: slide.midY)
        }
    }
}

/// The checkerboard under a transparent slide, drawn only where the slide is
/// in view: at 800% the whole slide would be tens of thousands of squares.
struct CanvasCheckerboard: View {
    let navigator: CanvasNavigator

    var body: some View {
        GeometryReader { proxy in
            let slide = navigator.viewport(in: proxy.size)
                .viewRect(fromCanvas: CGRect(origin: .zero, size: navigator.canvasSize))
            let shown = slide.intersection(CGRect(origin: .zero, size: proxy.size))
            if !shown.isNull, shown.width > 0, shown.height > 0 {
                TransparencyGrid(
                    square: 12,
                    phase: CGPoint(x: shown.minX - slide.minX, y: shown.minY - slide.minY))
                    .frame(width: shown.width, height: shown.height)
                    .position(x: shown.midX, y: shown.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The zoom readout and − / + in the canvas's bottom corner, the same in
/// every editor.
struct CanvasZoomControl: View {
    let model: SlideEditorModel
    /// The canvas's size, so the readout follows Fit as the window resizes.
    let viewSize: CGSize

    private var navigator: CanvasNavigator { model.canvasNavigator }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                navigator.step(up: false, focus: model.canvasSelectionBounds)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out")

            Menu {
                Button("Fit") { navigator.fit() }
                Divider()
                ForEach([0.5, 1, 2, 4], id: \.self) { (scale: CGFloat) in
                    Button("\(Int(scale * 100))%") { navigator.zoom(to: scale) }
                }
                Divider()
                Button("Zoom to Selection") {
                    if let rect = model.canvasSelectionBounds { navigator.zoom(toSelection: rect) }
                }
                .disabled(model.selectedObjectIDs.isEmpty)
            } label: {
                Text("\(navigator.zoomPercent(in: viewSize))%")
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom. Pinch or ⌘-scroll to zoom, scroll or Space-drag to move around, ⌘0 to fit.")

            Button {
                navigator.step(up: true, focus: model.canvasSelectionBounds)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .help("Zoom in (⌘+)")
            .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
    }
}
