import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

/// The show view's right column: a live preview of every screen Screens is
/// driving — the room, the livestream and the stage first, then any other
/// outputs. Each can be hidden from the column; all show by default, and
/// the column scrolls when they don't fit.
struct MonitorsPanel: View {
    let render: RenderContext
    /// What's live on the audience screen; when it changes, that card's edge
    /// lights briefly, like a switcher's tally, to confirm the take.
    var liveKey: String? = nil
    /// Clears every layer on every screen; the one button the column keeps.
    var onClearAll: (() -> Void)? = nil
    /// Sends typed messages to the stage screen.
    var controls: ServiceControls? = nil
    /// Opens the stage layout in the editor.
    var onEditStage: (() -> Void)? = nil
    @State private var tally = false
    @Bindable private var setup = ShowSetup.shared
    @Environment(\.openSettings) private var openSettings

    /// Screens hidden from this column, by target id ("" separated by
    /// newlines). Kept per Mac: it's only about this window.
    @AppStorage("monitors.hidden") private var hiddenList = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The column's width, measured outside the scroll view: previews get an
    /// exact size from it, so their embedded views never resize while the
    /// split view measures them (that loop ends the app).
    @State private var columnWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            header
                .onChange(of: liveKey) { _, key in
                    guard key != nil else { return }
                    tally = true
                    withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.8).delay(0.25)) { tally = false }
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shows(audienceTarget) {
                        monitor("Audience", target: audienceTarget, color: HopeStyle.blue) { target in
                            LiveSceneView(render: render, screenTargetID: target)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(HopeStyle.blue.opacity(tally ? 0.9 : 0), lineWidth: 1.5)
                                .allowsHitTesting(false)
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
            .animation(HopeMotion.ui(reduced: reduceMotion), value: hiddenList)

            if let onClearAll {
                Divider()
                Button(action: onClearAll) {
                    Label("Clear All", systemImage: "xmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .tint(nil)
                .keyboardShortcut(.escape, modifiers: [.shift])
                .help("Clear every screen (⇧Esc)")
                .padding(12)
            }
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
    private let previewHeight: CGFloat = 340

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
                // One click puts the audience screen on the stage too, and
                // one more puts back what it showed.
                Toggle(isOn: $setup.showsAudienceOnStage) {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(setup.showsAudienceOnStage
                    ? "Stop showing the audience screen on the stage display"
                    : "Show the audience screen on the stage display")
                // What the stage shows, as a small menu rather than a row of
                // buttons under the preview.
                Menu {
                    Picker("Show", selection: $setup.stageMode) {
                        ForEach(ShowSetup.StageMode.allCases.filter { $0 != .mirror }) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show Audience Screen", isOn: $setup.showsAudienceOnStage)
                    if let onEditStage {
                        Divider()
                        Button("Edit Stage Display…", action: onEditStage)
                    }
                } label: {
                    Text(setup.stageMode.title)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Worship: lyrics, next slide, clock and key. Message: the sermon timer and the clock. Audience Screen: what the audience sees. A playing video shows on the stage with the time left.")
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
            if let controls {
                SermonTimerControl(controls: controls)
                StageMessageField(controls: controls)
            }
        }
        .screenCard(HopeStyle.amber)
    }

    @ViewBuilder
    private var streamMonitor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ScreenLabel(title: "Livestream", color: HopeStyle.stagePurple)
                Spacer()
                if controls?.screenVideoID != nil {
                    Text("Video")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                        .help("A video is playing, so the livestream shows it full screen. When it ends the livestream goes clear until the next slide.")
                }
                if streamTarget != nil {
                    // What goes over the camera, as a small menu rather than a
                    // row of buttons under the preview.
                    Picker("Livestream", selection: $setup.streamMode) {
                        ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Auto: slides whose theme has a livestream lower third show in it; everything else leaves the camera clear. Full Screen: the room's screen, edge to edge. Off: nothing over the camera.")
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

/// A message to whoever is on stage: typed, sent, shown large on the stage
/// screen (in place of the clock and key in Worship) for the time set in
/// Settings › Show Setup, or until cleared. Sending (or Escape) hands the
/// keyboard back to the window, so Space and the arrows move the slides
/// again rather than typing into the field.
struct StageMessageField: View {
    let controls: ServiceControls
    /// After a send or Escape: where the show's keys go back to, when the
    /// window's own handling isn't enough (Simple Mode's focus).
    var onDone: () -> Void = {}
    @State private var draft = ""

    private var onStage: CueAlert? {
        guard let live = controls.state.liveAlert, live.showsOnConfidence else { return nil }
        return live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Message to stage", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(send)
                    .onExitCommand { done() }
                Button("Send", action: send)
                    .controlSize(.small)
                    .disabled(trimmed.isEmpty)
            }
            if let onStage {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(onStage.message)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    StageMessageCountdown(alert: onStage)
                    Button("Clear") { controls.dismissAlert() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
                .help("On the stage screen now")
            }
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        controls.fireAlert(id: "stage-message", message: trimmed, behavior: .persist, target: .confidence)
        draft = ""
        done()
    }

    private func done() {
        KeyboardFocus.release()
        onDone()
    }
}

/// The time left before a stage message clears itself, counting down on its
/// own (no clock of ours ticks it). Nothing for one that stays until cleared.
struct StageMessageCountdown: View {
    let alert: CueAlert

    var body: some View {
        if let expiresAt = alert.expiresAt, expiresAt > alert.firedAt {
            Text(timerInterval: alert.firedAt...expiresAt, countsDown: true)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)
                .help("Clears from the stage by itself then (Settings › Show Setup › Stage messages)")
        }
    }
}

/// Typing in a small field beside the show shouldn't keep the show's keys:
/// while a text field has the keyboard, Space and the arrows type instead of
/// moving the slides.
@MainActor
enum KeyboardFocus {
    /// Ends typing in the key window, and in the main window once a popover
    /// over it has closed.
    static func release() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) where window.firstResponder is NSText {
                window.makeFirstResponder(nil)
            }
        }
    }
}

/// The sermon timer, always to hand under the stage preview: the time left
/// (green, red once it's past 0:00), start and pause, back to the start, a
/// minute more or less, and an exact length. Each change shows on the stage
/// at once, running or not.
struct SermonTimerControl: View {
    let controls: ServiceControls
    /// After the minutes are set or the form closes, as StageMessageField's.
    var onDone: () -> Void = {}
    @State private var settingLength = false
    @State private var minutesText = ""

    var body: some View {
        let timer = controls.sermonTimer
        let running = timer?.isRunning == true
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SERMON")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Button {
                    minutesText = "\(Int(((timer?.durationSeconds ?? SermonTimer.defaultSeconds) / 60).rounded()))"
                    settingLength = true
                } label: {
                    SermonTimeReadout(timer: timer)
                }
                .buttonStyle(.plain)
                .help("Set the time left")
                .popover(isPresented: $settingLength, arrowEdge: .bottom) {
                    lengthForm.onDisappear {
                        KeyboardFocus.release()
                        onDone()
                    }
                }
            }
            Spacer(minLength: 4)
            Group {
                Button("−1") { controls.adjustSermonTimer(byMinutes: -1) }
                    .help("A minute less")
                Button("+1") { controls.adjustSermonTimer(byMinutes: 1) }
                    .help("A minute more")
                Button { controls.toggleSermonTimer() } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(running ? "Pause the sermon timer" : "Start the sermon timer")
                Button { controls.resetSermonTimer() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Back to the full length, stopped")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var lengthForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sermon Timer").font(.headline)
            HStack(spacing: 6) {
                TextField("Minutes", text: $minutesText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit(setLength)
                Text("minutes")
            }
            Text("Shows this much time now, and keeps running if it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { settingLength = false }
                Button("Set", action: setLength)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typedMinutes == nil)
            }
        }
        .padding(12)
        .frame(width: 230)
    }

    private var typedMinutes: Int? {
        Int(minutesText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private func setLength() {
        guard let minutes = typedMinutes else { return }
        controls.setSermonTimer(minutes: minutes)
        settingLength = false
    }
}

/// The sermon timer's digits: the only part that ticks, so the card around
/// it isn't redrawn twice a second.
private struct SermonTimeReadout: View {
    let timer: TimerSnapshot?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let overtime = timer?.isOvertime(at: context.date) == true
            Text(timer?.displayString(at: context.date) ?? TimerSnapshot.timecode(SermonTimer.defaultSeconds))
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(overtime ? Color.red : Color.green)
        }
    }
}
