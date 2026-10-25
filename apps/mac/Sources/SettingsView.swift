import AppKit
import PresenterCore
import SwiftUI

/// Settings (⌘,): a sidebar of sections and a grouped form for each. Every
/// setting is listed once in SettingsIndex, which the search reads and the
/// panes take their words from, so a result always names what the pane
/// shows and jumping to it can find the row.
struct AppSettingsView: View {

    var model: AppModel?
    let controls: ServiceControls?

    var layout: PresentLayoutController?

    var api: LocalAPIController?

    @State private var pinFlow: PinFlow?

    @State private var entering: RunOnlyEntry?

    @State private var afterEntrySheet: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    /// The section shown last, so Settings opens where it was left.
    @AppStorage("settings.lastSection") private var lastSection = SettingsCategory.general.rawValue
    @AppStorage(IntegrationTab.defaultsKey) private var integrationTabRaw = IntegrationTab.anthem.rawValue

    @State private var query = ""
    /// The row a search result (or another window) asked for; it is
    /// scrolled to and tinted for a moment.
    @State private var highlight: String?
    @State private var highlightGeneration = 0

    private var category: SettingsCategory {
        SettingsCategory(storedID: lastSection) ?? .general
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            detail
                .navigationTitle(query.isEmpty ? category.title : "Search Results")
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 800, idealWidth: 880, minHeight: 540, idealHeight: 660)
        .background(Color.basePlane)
        .environment(\.settingsHighlight, highlight)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
        .onAppear { takePending() }
        .onChange(of: SettingsRouter.shared.pending) { _, _ in takePending() }
        .sheet(item: $pinFlow) { flow in
            PasscodeSheet(
                flow: flow,
                verify: { layout?.verifyPIN($0) ?? false },
                waitSeconds: { layout?.pinWaitSeconds() ?? 0 }
            ) { pin in
                layout?.setPIN(pin)
            }
        }
        .sheet(item: $entering, onDismiss: {
            afterEntrySheet?()
            afterEntrySheet = nil
        }) { entry in
            RunOnlyEntrySheet(
                needsPIN: layout?.hasPIN != true,
                initial: entry.saved?.volunteerModules
                    ?? layout?.suggestedRunOnlyModules ?? ServiceControlsModule.defaultOrder
            ) { pin, modules in
                if let pin { layout?.setPIN(pin) }
                if let saved = entry.saved {
                    layout?.setLayoutRunOnlyModules(id: saved.id, modules)
                }
                layout?.setRunOnlyModules(modules)
                afterEntrySheet = { enterRunOnly(applying: entry.saved, closing: entry.settingsWindow) }
            }
        }
    }

    // MARK: Navigation

    private func takePending() {
        let router = SettingsRouter.shared
        guard let pending = router.pending else { return }
        router.pending = nil
        if let entry = router.pendingEntry.flatMap(SettingsIndex.entry) {
            router.pendingEntry = nil
            jump(to: entry)
        } else {
            query = ""
            lastSection = pending.rawValue
        }
    }

    private func jump(to entry: SettingsEntry) {
        query = ""
        lastSection = entry.category.rawValue
        if let tab = entry.tab { integrationTabRaw = tab.rawValue }
        highlightGeneration += 1
        let generation = highlightGeneration
        highlight = entry.id
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if highlightGeneration == generation { highlight = nil }
        }
    }

    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(
            get: { query.isEmpty ? category : nil },
            set: { picked in
                guard let picked else { return }
                query = ""
                highlight = nil
                lastSection = picked.rawValue
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(SettingsCategory.sidebarGroups, id: \.self) { group in
                Section {
                    ForEach(group) { entry in
                        Label {
                            Text(entry.title)
                        } icon: {
                            SettingsIconTile(category: entry)
                        }
                        .tag(entry)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if query.isEmpty {
            ScrollViewReader { proxy in
                pane(for: category)
                    .id(category)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: highlightGeneration) {
                        guard let target = highlight else { return }
                        // The pane lays out first; then the row can be found.
                        try? await Task.sleep(for: .milliseconds(120))
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
            }
        } else {
            SettingsSearchResults(query: query) { jump(to: $0) }
        }
    }

    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        switch category {
        case .general:
            generalPane
        case .screens:
            if let controls {
                ScreensSettingsPane(render: controls.render)
            } else {
                SettingsUnavailable(text: "Screens need Metal, which isn't available on this Mac.")
            }
        case .livestream:
            LivestreamSettingsPane(model: model, controls: controls)
        case .stage:
            StageSettingsPane(model: model, controls: controls)
        case .slides:
            SlidesSettingsPane(model: model)
        case .bible:
            BibleSettingsPane(model: model)
        case .liveListening:
            LiveListeningSettingsPane()
        case .media:
            MediaSettingsPane()
        case .integrations:
            IntegrationsSettingsPane(
                model: model, api: api,
                tab: Binding(
                    get: { IntegrationTab(rawValue: integrationTabRaw) ?? .anthem },
                    set: { integrationTabRaw = $0.rawValue }))
        case .keyboard:
            if let model {
                KeyboardMapPane(model: model, controls: controls)
                    .settingsAnchor("keyboard.shortcuts")
            } else {
                SettingsUnavailable(text: "The library hasn't opened.")
            }
        case .assistant:
            AssistantSettingsPane(model: model)
        case .advanced:
            AdvancedSettingsPane()
        }
    }

    // MARK: General

    @AppStorage("present.continuous") private var continuousPresent = true
    @AppStorage(ServiceStation.runsServiceKey) private var runsService = false

    private var generalPane: some View {
        Form {
            Section {
                SettingsToggle("present.continuous", isOn: $continuousPresent)
                if let layout {
                    SettingsRow("present.layouts") {
                        PresentLayoutMenuControl(layout: layout) { saved in
                            requestRunOnly(applying: saved)
                        }
                    }
                }
            } header: {
                Text("Present")
            }
            if let layout {
                Section {
                    SettingsRow("present.runOnly") {
                        HStack(spacing: 8) {
                            if layout.hasPIN {
                                Button("Change Passcode…") { pinFlow = .change }
                            }
                            Button("Enter Simple Mode…") { requestRunOnly(applying: nil) }
                        }
                    }
                } header: {
                    Text("Simple Mode")
                }
            }
            Section {
                SettingsToggle("general.runsService", isOn: $runsService)
            } header: {
                Text("Service Day")
            } footer: {
                Text(runsService
                    ? "A restart goes ahead only over empty screens, the end of the plan or stopped pre-service slides, or after 20 minutes on the plan's last item."
                    : "This Mac skips the countdowns and pre-service restarts.")
            }
        }
        .settingsForm()
    }

    // MARK: Simple Mode

    private func requestRunOnly(applying saved: PresentLayout?) {
        let settingsWindow = NSApp.keyWindow
        if let savedModules = saved?.volunteerModules, layout?.hasPIN == true {
            layout?.setRunOnlyModules(savedModules)
            enterRunOnly(applying: saved, closing: settingsWindow)
        } else {
            entering = RunOnlyEntry(saved: saved, settingsWindow: settingsWindow)
        }
    }

    private func enterRunOnly(applying saved: PresentLayout?, closing settingsWindow: NSWindow?) {
        layout?.enterRunOnly(applying: saved.map { saved in
            { layout?.apply(saved, openWindow: openWindow, dismissWindow: dismissWindow) }
        })
        settingsWindow?.close()
    }
}

// MARK: - Sections

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case screens
    case livestream
    case stage
    case slides
    case bible
    case liveListening
    case media
    case integrations
    case keyboard
    case assistant
    case advanced

    var id: String { rawValue }

    /// The sidebar's runs, divided like System Settings: the room, the
    /// content, then what connects to it.
    static let sidebarGroups: [[SettingsCategory]] = [
        [.general, .screens, .livestream, .stage],
        [.slides, .bible, .liveListening, .media],
        [.integrations, .keyboard, .assistant, .advanced],
    ]

    /// A stored section name, including the ones before Settings was
    /// regrouped: keyboard shortcuts saved as "Open Settings › Show Setup"
    /// and the last section a Mac had open still land somewhere sensible.
    init?(storedID: String) {
        if let current = SettingsCategory(rawValue: storedID) {
            self = current
            return
        }
        switch storedID {
        case "showSetup": self = .screens
        case "present", "appearance": self = .general
        case "avInputs": self = .media
        case "midi", "shepherd", "api": self = .integrations
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .screens: "Screens"
        case .livestream: "Livestream"
        case .stage: "Stage"
        case .slides: "Slides & Themes"
        case .bible: "Bible"
        case .liveListening: "Live Listening"
        case .media: "Media & Video"
        case .integrations: "Integrations"
        case .keyboard: "Keyboard"
        case .assistant: "Assistant"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .screens: "display.2"
        case .livestream: "dot.radiowaves.left.and.right"
        case .stage: "music.mic"
        case .slides: "rectangle.on.rectangle"
        case .bible: "book.closed"
        case .liveListening: "waveform"
        case .media: "video"
        case .integrations: "puzzlepiece.extension"
        case .keyboard: "keyboard"
        case .assistant: "sparkles"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .screens: .blue
        case .livestream: .red
        case .stage: .orange
        case .slides: .indigo
        case .bible: .brown
        case .liveListening: .pink
        case .media: .teal
        case .integrations: .green
        case .keyboard: .gray
        case .assistant: .purple
        case .advanced: .gray
        }
    }
}

/// The four groups inside Integrations, one at a time so each reads as a
/// short page.
enum IntegrationTab: String, CaseIterable, Identifiable {
    case anthem, lightkey, shepherd, remote

    static let defaultsKey = "settings.integrationsTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthem: "Anthem"
        case .lightkey: "Lightkey & MIDI"
        case .shepherd: "Shepherd"
        case .remote: "Remote & API"
        }
    }
}

/// Opens Settings at a section (and optionally a row) from anywhere: a menu,
/// a keyboard shortcut, another window.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var pending: SettingsCategory?
    /// A SettingsIndex id to scroll to and highlight once the section shows.
    var pendingEntry: String?
    private init() {}

    func open(_ category: SettingsCategory, entry: String? = nil) {
        pendingEntry = entry
        pending = category
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct SettingsIconTile: View {
    let category: SettingsCategory

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(category.tint.gradient)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Search

struct SettingsSearchResults: View {
    let query: String
    let choose: (SettingsEntry) -> Void

    var body: some View {
        let matches = SettingsIndex.matching(query)
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Form {
                ForEach(SettingsCategory.allCases) { category in
                    let rows = matches.filter { $0.category == category }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { entry in
                                Button { choose(entry) } label: { resultRow(entry) }
                                    .buttonStyle(.plain)
                            }
                        } header: {
                            Text(category.title)
                        }
                    }
                }
            }
            .settingsForm()
        }
    }

    private func resultRow(_ entry: SettingsEntry) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(category: entry.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.breadcrumb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let caption = entry.caption {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Rows

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The SettingsIndex id being pointed out after a search.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        let lit = highlight == id
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(lit ? 0.22 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: lit ? 0.2 : 0.8), value: lit)
    }
}

extension View {
    /// Marks the view as the place a search result for `id` lands.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(id: id))
    }

    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.basePlane)
    }
}

/// A labelled row whose words come from SettingsIndex.
struct SettingsRow<Control: View>: View {
    let entry: SettingsEntry
    let control: Control

    init(_ id: String, @ViewBuilder control: () -> Control) {
        entry = SettingsIndex.entry(id) ?? SettingsEntry(id: id, category: .general, title: id)
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
        } label: {
            SettingsLabel(entry: entry)
        }
        .settingsAnchor(entry.id)
    }
}

/// A switch row whose words come from SettingsIndex.
struct SettingsToggle: View {
    let entry: SettingsEntry
    @Binding var isOn: Bool

    init(_ id: String, isOn: Binding<Bool>) {
        entry = SettingsIndex.entry(id) ?? SettingsEntry(id: id, category: .general, title: id)
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(entry: entry)
        }
        .toggleStyle(.switch)
        .settingsAnchor(entry.id)
    }
}

struct SettingsLabel: View {
    let entry: SettingsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
            if let caption = entry.caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A section header that is also a search landing spot.
struct SettingsHeader: View {
    let id: String

    var body: some View {
        Text(SettingsIndex.entry(id)?.title ?? id)
            .settingsAnchor(id)
    }
}

struct SettingsUnavailable: View {
    let text: String

    var body: some View {
        ContentUnavailableView(text, systemImage: "exclamationmark.triangle")
    }
}

struct SettingsPageHeader: View {
    let backTitle: String
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(backTitle).font(.system(size: 12))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

extension Toggle {

    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .labelsHidden()
    }
}

// MARK: - Controls

struct PresentLayoutMenuControl: View {
    let layout: PresentLayoutController

    let onPickRunOnly: (PresentLayout) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingSave = false
    @State private var showingRename = false
    @State private var nameDraft = ""

    var body: some View {
        let active = layout.activeLayoutID.flatMap { layout.layout(id: $0) }
        Menu {
            ForEach(layout.layouts) { saved in
                Toggle(saved.name, isOn: Binding(
                    get: { layout.activeLayoutID == saved.id },
                    set: { _ in apply(saved) }
                ))
            }
            if !layout.layouts.isEmpty { Divider() }
            Button("Save Current as Layout…") {
                nameDraft = ""
                showingSave = true
            }
            if let active {
                Button("Update “\(active.name)”") {
                    layout.updateLayout(id: active.id)
                }
                Button("Rename…") {
                    nameDraft = active.name
                    showingRename = true
                }

                Picker("Run-Only Layout", selection: Binding(
                    get: { active.runOnly },
                    set: { layout.setLayoutRunOnly(id: active.id, $0) }
                )) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
                Divider()
                Button("Delete “\(active.name)”", role: .destructive) {
                    layout.deleteLayout(id: active.id)
                }
            }
        } label: {
            Text(active?.name ?? "Layouts")
        }
        .fixedSize()
        .alert("Save Layout", isPresented: $showingSave) {
            TextField("Name", text: $nameDraft)
            Button("Save") { layout.saveLayout(named: nameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captures the current arrangement — panels, sizes, and windows.")
        }
        .alert("Rename Layout", isPresented: $showingRename) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let id = layout.activeLayoutID {
                    layout.renameLayout(id: id, to: nameDraft)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func apply(_ saved: PresentLayout) {
        if saved.runOnly {
            onPickRunOnly(saved)
        } else {
            layout.apply(saved, openWindow: openWindow, dismissWindow: dismissWindow)
        }
    }
}

struct DefaultAnimationsControl: View {
    let model: AppModel?

    private static let choices: [StepAnimation] = [.fade, .move, .scale, .wipe, .blur]

    var body: some View {
        if let model {
            VStack(alignment: .trailing, spacing: 6) {
                row("In", step: model.animationDefaultIn, kind: .in, model: model)
                row("Out", step: model.animationDefaultOut, kind: .out, model: model)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, step: AnimationStep, kind: AnimationKind, model: AppModel) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Picker("", selection: Binding(
                get: { step.animation },
                set: { choice in write(kind, model) { $0.animation = choice } }
            )) {
                ForEach(Self.choices, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                if !Self.choices.contains(step.animation) {
                    Text(step.animation.rawValue.capitalized).tag(step.animation)
                }
            }
            .labelsHidden()
            .frame(width: 96)
            Picker("", selection: Binding(
                get: { SlideEditorModel.AnimationSpeed.of(step.durationSeconds) },
                set: { speed in
                    if let seconds = speed.seconds {
                        write(kind, model) { $0.durationSeconds = seconds }
                    }
                }
            )) {
                ForEach([.quick, .normal, .slow] as [SlideEditorModel.AnimationSpeed], id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
                if SlideEditorModel.AnimationSpeed.of(step.durationSeconds) == .custom {
                    Text(String(format: "%.1fs", step.durationSeconds))
                        .tag(SlideEditorModel.AnimationSpeed.custom)
                }
            }
            .labelsHidden()
            .frame(width: 96)
        }
    }

    private func write(_ kind: AnimationKind, _ model: AppModel, _ mutate: (inout AnimationStep) -> Void) {
        var step = kind == .out ? model.animationDefaultOut : model.animationDefaultIn
        mutate(&step)
        if kind == .out {
            model.setAnimationDefault(out: step)
        } else {
            model.setAnimationDefault(in: step)
        }
    }
}

struct DefaultTransitionControl: View {
    let kindKey: String
    let durationKey: String
    var fallbackKind = ""
    var fallbackDuration = 0.5

    @State private var kindRaw = ""
    @State private var duration = 0.5

    var body: some View {
        controls
            .onAppear {
                kindRaw = UserDefaults.standard.string(forKey: kindKey) ?? fallbackKind
                let stored = UserDefaults.standard.double(forKey: durationKey)
                duration = stored > 0 ? stored : fallbackDuration
            }

    }

    private var storedKind: Binding<String> {
        Binding(
            get: { kindRaw },
            set: { v in
                kindRaw = v
                UserDefaults.standard.set(v, forKey: kindKey)
            }
        )
    }

    private var storedDuration: Binding<Double> {
        Binding(
            get: { duration },
            set: { v in
                duration = v
                UserDefaults.standard.set(v, forKey: durationKey)
            }
        )
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if !kindRaw.isEmpty {
                Stepper(
                    String(format: "%.2gs", duration),
                    value: storedDuration, in: 0 ... 5, step: 0.1
                )
                .monospacedDigit()
            }
            Picker("", selection: storedKind) {
                Text("Cut").tag("")
                Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }
}
