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
struct TransparentScenePreview: NSViewRepresentable {
    let compositor: Compositor
    let provider: @Sendable () -> RenderScene
    /// The same ceiling as the other previews; the folded strip asks for less.
    var maximumFramesPerSecond: Float = 30

    func makeNSView(context: Context) -> TransparentScenePreviewNSView {
        let view = TransparentScenePreviewNSView(compositor: compositor, provider: provider)
        view.maximumFramesPerSecond = maximumFramesPerSecond
        return view
    }

    func updateNSView(_ view: TransparentScenePreviewNSView, context: Context) {
        view.provider = provider
    }
}

@MainActor
final class TransparentScenePreviewNSView: NSView {
    var provider: @Sendable () -> RenderScene
    var maximumFramesPerSecond: Float = 30
    private let compositor: Compositor
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?

    init(compositor: Compositor, provider: @escaping @Sendable () -> RenderScene) {
        self.compositor = compositor
        self.provider = provider
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer {
        metalLayer.device = compositor.device
        metalLayer.pixelFormat = Compositor.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: Compositor.workingColorSpaceName)
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = .clear
        return metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        resize()
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        let most = max(1, maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, most), maximum: most, preferred: most)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layout() {
        super.layout()
        resize()
    }

    private func resize() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

extension TransparentScenePreviewNSView: CAMetalDisplayLinkDelegate {
    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        nonisolated(unsafe) let drawable = update.drawable
        MainActor.assumeIsolated {
            compositor.render(
                scene: provider(), into: drawable, at: CACurrentMediaTime(), transparentBackground: true)
        }
    }
}
