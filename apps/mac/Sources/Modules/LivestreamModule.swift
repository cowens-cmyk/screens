import AppKit
import Metal
import OutputEngine
import PresenterCore
import QuartzCore
import RenderEngine
import SwiftUI

/// The livestream screen as the stream sees it: drawn over a checkerboard so
/// transparency shows, with a badge for what's over the camera — nothing,
/// a lower third, or a full-screen takeover — and the stream Looks.
struct LivestreamModule: View {
    let model: AppModel
    let controls: ServiceControls
    let presets: OutputPresetsController?

    @AppStorage("livestream.screenID") private var screenID = ""
    @Environment(\.runOnly) private var runOnly
    @State private var coverage: StreamCoverage = .transparent
    @State private var settingUp = false

    private var outputs: OutputManager { controls.render.outputs }

    private var screen: PlaceholderScreen? {
        let screens = outputs.placeholderScreens
        if let chosen = screens.first(where: { $0.id.uuidString == screenID }) { return chosen }
        return screens.first { screen in
            let name = screen.name.lowercased()
            return ["stream", "live", "lower", "broadcast"].contains { name.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: Binding(
                    get: { screen?.id.uuidString ?? "" },
                    set: { screenID = $0 }
                )) {
                    Text("Choose the stream screen…").tag("")
                    ForEach(outputs.placeholderScreens) { Text($0.name).tag($0.id.uuidString) }
                }
                .labelsHidden()
                .controlSize(.small)
                Spacer()
                CoverageBadge(coverage: coverage)
            }
            if let screen {
                ZStack {
                    Checkerboard()
                    TransparentScenePreview(
                        compositor: controls.render.compositor,
                        provider: outputs.previewProvider(for: screen.id.uuidString))
                }
                .aspectRatio(CGFloat(screen.width) / CGFloat(max(screen.height, 1)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .task(id: screen.id) { await watch(screen) }
            } else {
                Text("Add a screen for the livestream in Screen Configuration (assign it to the DeckLink output with Alpha Key on), then pick it here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let presets {
                streamLooks(presets)
            }
        }
        .sheet(isPresented: $settingUp) {
            if let presets, let screen {
                StreamLooksSetupSheet(model: model, presets: presets, screen: screen)
            }
        }
    }

    @ViewBuilder
    private func streamLooks(_ presets: OutputPresetsController) -> some View {
        let streamLooks = presets.presets.filter { $0.name.hasPrefix(StreamLooksSetupSheet.prefix) }
        HStack(spacing: 6) {
            ForEach(streamLooks, id: \.id) { look in
                let active = presets.activePresetID == look.id
                Button(String(look.name.dropFirst(StreamLooksSetupSheet.prefix.count))) {
                    presets.activate(active ? nil : look.id)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(active ? .accentColor : nil)
            }
            Spacer()
            if !runOnly, screen != nil {
                Button(streamLooks.isEmpty ? "Set Up Stream Looks…" : "Rebuild…") { settingUp = true }
                    .controlSize(.small)
            }
        }
    }

    /// The scene is cheap to classify; a few times a second is plenty for a badge.
    private func watch(_ screen: PlaceholderScreen) async {
        let provider = outputs.previewProvider(for: screen.id.uuidString)
        while !Task.isCancelled {
            let next = StreamCoverage.classify(provider())
            if next != coverage { coverage = next }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

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

private struct Checkerboard: View {
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

    func makeNSView(context: Context) -> TransparentScenePreviewNSView {
        TransparentScenePreviewNSView(compositor: compositor, provider: provider)
    }

    func updateNSView(_ view: TransparentScenePreviewNSView, context: Context) {
        view.provider = provider
    }
}

@MainActor
final class TransparentScenePreviewNSView: NSView {
    var provider: @Sendable () -> RenderScene
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
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

/// Builds the three stream Looks. Each only routes the stream screen, so the
/// room's screens are left as they are:
/// - Camera Only: nothing over the camera except overlays you fire.
/// - Lower Thirds: slides drawn by your lower-third theme (its "Bible",
///   "Sermon Points", "Lyrics" categories), over transparency.
/// - Full Screen: exactly what the room sees, edge to edge.
struct StreamLooksSetupSheet: View {
    let model: AppModel
    let presets: OutputPresetsController
    let screen: PlaceholderScreen

    static let prefix = "Stream: "

    @Environment(\.dismiss) private var dismiss
    @State private var lowerThirdThemeID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream Looks for “\(screen.name)”").font(.headline)
            Text("Creates three Looks that only change the stream screen: Camera Only, Lower Thirds and Full Screen. Link them to theme categories (Bible → Lower Thirds, Lyrics → Camera Only) or add them as slide actions.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Lower-third theme", selection: $lowerThirdThemeID) {
                Text("Choose…").tag("")
                ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
            }
            Text("Its categories are matched by name: your Bible slides use its “Bible” category, points use “Sermon Points”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Looks", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lowerThirdThemeID.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func create() {
        for existing in presets.presets where existing.name.hasPrefix(Self.prefix) {
            presets.deletePreset(existing.id)
        }
        let target = screen.id.uuidString
        let overlays = [LayerKind.overlays.rawValue, LayerKind.alerts.rawValue]
        presets.createPreset(name: Self.prefix + "Camera Only", assignments: [
            OutputAssignment(targetKind: .placeholderScreen, targetId: target, enabledLayers: overlays),
        ])
        var lowerThirds = OutputAssignment(
            targetKind: .placeholderScreen, targetId: target,
            enabledLayers: [LayerKind.slide.rawValue] + overlays)
        lowerThirds.slideThemeId = lowerThirdThemeID
        presets.createPreset(name: Self.prefix + "Lower Thirds", assignments: [lowerThirds])
        presets.createPreset(name: Self.prefix + "Full Screen", assignments: [
            OutputAssignment(
                targetKind: .placeholderScreen, targetId: target,
                enabledLayers: LayerKind.allCases.map(\.rawValue)),
        ])
        dismiss()
    }
}
