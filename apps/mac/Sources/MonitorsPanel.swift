import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

/// The show view's right column: what the room sees, what the livestream
/// puts over the camera, and what's on the stage display — always visible.
struct MonitorsPanel: View {
    let render: RenderContext
    @Bindable private var setup = ShowSetup.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                monitor("Audience", target: audienceTarget) { target in
                    LiveSceneView(render: render, screenTargetID: target)
                }
                streamMonitor
                stageMonitor
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Targets (Settings › Show Setup, else a sensible guess)

    private var targets: ShowTargets { ShowTargets(setup: setup, render: render) }
    private var stageTarget: String? { targets.stage }
    private var streamTarget: String? { targets.stream }
    private var audienceTarget: String? { targets.audience }

    // MARK: Monitors

    @ViewBuilder
    private func monitor(
        _ title: String, target: String?, @ViewBuilder content: (String) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let target {
                content(target)
                    .aspectRatio(PreviewTargets.aspect(of: target, render: render), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.separator.opacity(0.6)))
            } else {
                placeholder("Choose the \(title.lowercased()) screen in Settings › Show Setup")
            }
        }
    }

    /// The stage display follows its mode; a playing video takes it over.
    @ViewBuilder
    private var stageMonitor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                StageVideoBadge(render: render)
            }
            if let stageTarget {
                LiveSceneView(render: render, screenTargetID: stageTarget)
                    .modifier(PreviewedLayoutKeeper(target: stageTarget))
                    .aspectRatio(PreviewTargets.aspect(of: stageTarget, render: render), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.separator.opacity(0.6)))
            } else {
                placeholder("Choose the stage screen in Settings › Show Setup")
            }
            Picker("", selection: $setup.stageMode) {
                ForEach(ShowSetup.StageMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Worship: lyrics, next slide, clock and key. Message: sermon timer, clock, slide and notes. Mirror: what the audience sees. A playing video shows on the stage with the time left.")
        }
    }

    @ViewBuilder
    private var streamMonitor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Livestream").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let streamTarget {
                    StreamCoverageBadge(provider: render.outputs.previewProvider(for: streamTarget))
                }
            }
            if let streamTarget {
                ZStack {
                    Checkerboard()
                    TransparentScenePreview(
                        compositor: render.compositor,
                        provider: render.outputs.previewProvider(for: streamTarget))
                }
                .aspectRatio(PreviewTargets.aspect(of: streamTarget, render: render), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.separator.opacity(0.6)))
                Picker("", selection: $setup.streamMode) {
                    ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Auto: slides whose theme has a livestream lower third show in it; everything else leaves the camera clear. Full Screen: the room's screen, edge to edge. Off: nothing over the camera.")
            } else {
                placeholder("Choose the livestream screen in Settings › Show Setup")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Button { openSettings() } label: {
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// Transparent / Lower Third / Full Screen, from what the stream renders.
struct StreamCoverageBadge: View {
    let provider: @Sendable () -> RenderScene
    @State private var coverage: StreamCoverage = .transparent

    var body: some View {
        CoverageBadge(coverage: coverage)
            .task {
                while !Task.isCancelled {
                    let next = StreamCoverage.classify(provider())
                    if next != coverage { coverage = next }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}

/// Timers and Macros, one tap apart; everything else lives in the Service
/// Controls window.
struct ShowControlsPanel: View {
    let model: AppModel
    let controls: ServiceControls

    enum Tab: String, CaseIterable { case timers = "Timers", macros = "Macros", sermon = "Sermon" }
    @AppStorage("show.controlsTab") private var tab: Tab = .timers
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    openWindow(id: "serviceControls")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .help("More controls — music, overlays, alerts, signage, outputs")
            }
            .padding(10)
            ScrollView {
                Group {
                    switch tab {
                    case .timers: TimersModule(model: model, controls: controls)
                    case .macros: ActionCombosModule(model: model, controls: controls)
                    case .sermon: SermonPanel()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }
}
