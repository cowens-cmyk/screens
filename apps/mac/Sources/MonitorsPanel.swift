import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

/// The show view's right column: a live preview of every screen Screens is
/// driving — the room, the livestream and the stage first, then any other
/// outputs. Each can be hidden from the column; all show by default, and
/// the column scrolls when they don't fit.
struct MonitorsPanel: View {
    let render: RenderContext
    @Bindable private var setup = ShowSetup.shared
    @Environment(\.openSettings) private var openSettings

    /// Screens hidden from this column, by target id ("" separated by
    /// newlines). Kept per Mac: it's only about this window.
    @AppStorage("monitors.hidden") private var hiddenList = ""

    /// The column's width, measured outside the scroll view: previews get an
    /// exact size from it, so their embedded views never resize while the
    /// split view measures them (that loop ends the app).
    @State private var columnWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shows(audienceTarget) {
                        monitor("Audience", target: audienceTarget, color: HopeStyle.blue) { target in
                            LiveSceneView(render: render, screenTargetID: target)
                        }
                    }
                    if shows(streamTarget) { streamMonitor }
                    if shows(stageTarget) { stageMonitor }
                    ForEach(otherScreens.filter { shows($0.id) }, id: \.id) { screen in
                        monitor(screen.name, target: screen.id) { target in
                            LiveSceneView(render: render, screenTargetID: target)
                        }
                    }
                    if allHidden {
                        Text("Every screen is hidden. Turn them back on from Screens above.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
        }

        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let rounded = (width / 4).rounded(.down) * 4
            if abs(rounded - columnWidth) >= 4 { columnWidth = rounded }
        }
    }

    /// A preview's exact size: the column's width (less padding) at the
    /// screen's shape, no taller than `previewHeight`.
    private func previewSize(_ target: String) -> CGSize {
        let aspect = max(PreviewTargets.aspect(of: target, render: render), 0.1)
        // 24 for padding, 16 always kept for a scroll bar: a preview sized
        // to the room the bar leaves would flip the bar on and off forever.
        let width = max(columnWidth - 60, 80)
        let height = min(width / aspect, previewHeight)
        return CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }

    // MARK: Which screens show

    private var header: some View {
        HStack {
            Text("Screens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(allScreens, id: \.id) { screen in
                    Toggle(screen.label, isOn: Binding(
                        get: { !hidden.contains(screen.id) },
                        set: { setHidden(screen.id, !$0) }))
                }
                Divider()
                Button("Show All") { hiddenList = "" }
            } label: {
                Image(systemName: "eye")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose which screens preview here")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var hidden: Set<String> {
        Set(hiddenList.split(separator: "\n").map(String.init))
    }

    private func setHidden(_ id: String, _ hide: Bool) {
        var ids = hidden
        if hide { ids.insert(id) } else { ids.remove(id) }
        hiddenList = ids.sorted().joined(separator: "\n")
    }

    /// A role with no screen assigned still shows, so its "choose a screen"
    /// hint stays reachable; it hides under the role's own name.
    private func shows(_ target: String?) -> Bool {
        !hidden.contains(target ?? "")
    }

    private var otherScreens: [(id: String, name: String)] {
        let roles = Set([audienceTarget, streamTarget, stageTarget].compactMap { $0 })
        return PreviewTargets.screens(render).filter { !roles.contains($0.id) }
    }

    private var allScreens: [(id: String, label: String)] {
        func name(_ id: String?) -> String {
            PreviewTargets.screens(render).first { $0.id == id }?.name ?? "not set"
        }
        var list: [(id: String, label: String)] = []
        if let audienceTarget { list.append((audienceTarget, "Audience — \(name(audienceTarget))")) }
        if let streamTarget { list.append((streamTarget, "Livestream — \(name(streamTarget))")) }
        if let stageTarget { list.append((stageTarget, "Stage — \(name(stageTarget))")) }
        list += otherScreens.map { ($0.id, $0.name) }
        return list
    }

    private var allHidden: Bool {
        let shown = [audienceTarget, streamTarget, stageTarget].filter { shows($0) }.count
            + otherScreens.filter { shows($0.id) }.count
        return shown == 0
    }

    /// Previews take the column's width at the screen's shape, up to this
    /// tall, so a portrait or very tall output doesn't fill the column.
    private let previewHeight: CGFloat = 260

    // MARK: Targets (Settings › Show Setup, else a sensible guess)

    private var targets: ShowTargets { ShowTargets(setup: setup, render: render) }
    private var stageTarget: String? { targets.stage }
    private var streamTarget: String? { targets.stream }
    private var audienceTarget: String? { targets.audience }

    // MARK: Monitors

    @ViewBuilder
    private func monitor(
        _ title: String, target: String?, color: Color = HopeStyle.lightBlue,
        @ViewBuilder content: (String) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScreenLabel(title: title, color: color)
            if let target {
                content(target)
                    .frame(width: previewSize(target).width, height: previewSize(target).height)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            } else {
                placeholder("Choose the \(title.lowercased()) screen in Settings › Show Setup")
            }
        }
        .screenCard(color)
    }

    /// The stage display follows its mode; a playing video takes it over.
    @ViewBuilder
    private var stageMonitor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ScreenLabel(title: "Stage", color: HopeStyle.amber)
                Spacer()
                StageVideoBadge(render: render)
            }
            if let stageTarget {
                LiveSceneView(render: render, screenTargetID: stageTarget)
                    .modifier(PreviewedLayoutKeeper(target: stageTarget))
                    .frame(width: previewSize(stageTarget).width, height: previewSize(stageTarget).height)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
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
        .screenCard(HopeStyle.amber)
    }

    @ViewBuilder
    private var streamMonitor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ScreenLabel(title: "Livestream", color: HopeStyle.stagePurple)
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
                .frame(width: previewSize(streamTarget).width, height: previewSize(streamTarget).height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
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
        .screenCard(HopeStyle.stagePurple)
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
                .help("More controls — alerts and stage layouts")
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

/// A screen's role, in its color: a dot and the name.
struct ScreenLabel: View {
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: Self.symbol(for: title))
                .foregroundStyle(color)
        }
    }

    /// Each role's SF Symbol, like an Apple app's sidebar.
    static func symbol(for title: String) -> String {
        switch title {
        case "Audience": "person.3.fill"
        case "Livestream": "dot.radiowaves.left.and.right"
        case "Stage": "music.mic"
        default: "display"
        }
    }
}

extension View {
    /// A screen preview's Liquid Glass card, faintly tinted with its role.
    func screenCard(_ color: Color) -> some View {
        padding(10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}
