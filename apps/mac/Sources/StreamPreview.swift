import AppKit
import Metal
import OutputEngine
import PresenterCore
import QuartzCore
import RenderEngine
import SwiftUI

struct CoverageBadge: View {
    let coverage: StreamCoverage

    var body: some View {
        let (label, color): (String, Color) = switch coverage {
        case .transparent: ("Transparent", .secondary)
        case .lowerThird: ("Lower Third", .green)
        case .fullScreen: ("Full Screen", .orange)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(coverage == .transparent ? Color.secondary : Color.white)
            .background(coverage == .transparent ? Color.primary.opacity(0.08) : color, in: Capsule())
            .help(help)
    }

    private var help: String {
        switch coverage {
        case .transparent: "Nothing over the camera"
        case .lowerThird: "Graphics over part of the camera — a lower third, lyrics or a logo"
        case .fullScreen: "The stream shows a full-screen slide, video or background"
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.gray.opacity(0.15))
    }
}

/// Renders a screen's scene with a transparent background into a
/// non-opaque layer, so whatever is behind it (the checkerboard) shows
/// where the stream is transparent.
///
/// This is a `MetalSceneView` like the other previews: it draws on the render
/// thread and only when the scene changes. It used to run its own display
/// link on the main thread and draw there on every refresh, which showed in
/// samples of the show Mac as main-thread time while nothing changed.
struct TransparentScenePreview: NSViewRepresentable {
    let compositor: Compositor
    let provider: @Sendable () -> RenderScene
    /// The same ceiling as the other previews; the folded strip asks for less.
    var maximumFramesPerSecond: Float = 30

    func makeNSView(context: Context) -> MetalSceneView {
        let view = MetalSceneView(compositor: compositor, transparentBackground: true)
        view.activity.kind = "preview"
        view.activity.label = "Livestream preview"
        view.maximumFramesPerSecond = maximumFramesPerSecond
        view.isPaused = context.environment.livePreviewsPaused
        view.sceneProvider = provider
        return view
    }

    func updateNSView(_ view: MetalSceneView, context: Context) {
        view.maximumFramesPerSecond = maximumFramesPerSecond
        // Out of sight in a folded panel: no drawing at all.
        view.isPaused = context.environment.livePreviewsPaused
        view.sceneProvider = provider
    }
}
