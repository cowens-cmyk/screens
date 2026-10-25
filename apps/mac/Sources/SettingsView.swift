import PresenterCore
import SwiftUI

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
    @AppStorage("present.continuous") private var continuousPresent = true
    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.transparencyGrid") private var transparencyGrid = true
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback
    @AppStorage(ServiceControls.nextSkipsBlanksKey) private var nextSkipsBlanks = true

    @State private var category: SettingsCategory = .present
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            nav
                .frame(width: 176)
            Divider()

            if query.isEmpty {
                SettingsCategoryPane(
                    category: category,
                    rows: allRows.filter { $0.category == category },
                    model: model, controls: controls)
                    .id(category)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 520)
        .background(Color.basePlane)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
        .onAppear {
            if let pending = SettingsRouter.shared.pending {
                category = pending
                SettingsRouter.shared.pending = nil
            }
        }
        .onChange(of: SettingsRouter.shared.pending) { _, pending in
            if let pending {
                category = pending
                SettingsRouter.shared.pending = nil
            }
        }
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

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .padding(.bottom, 10)
            // Only categories with something in them (Appearance is gone:
            // Screens is always dark).
            ForEach(SettingsCategory.allCases.filter { entry in allRows.contains { $0.category == entry } }) { entry in
                navRow(entry)
            }
            Spacer()
        }
        .padding(12)
    }

    private func navRow(_ entry: SettingsCategory) -> some View {
        let selected = query.isEmpty && category == entry
        return Button {
            query = ""
            category = entry
        } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                selected ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchResults: some View {
        let rows = visibleRows
        if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Form {
                ForEach(SettingsCategory.allCases) { entry in
                    let matches = rows.filter { $0.category == entry }
                    if !matches.isEmpty {
                        Section(entry.title) {
                            ForEach(matches) { spec in
                                if spec.stacked {
                                    LabeledContent {
                                        Button("Show") { query = ""; category = entry }
                                    } label: {
                                        Text(spec.title)
                                        if let caption = spec.caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                                    }
                                } else {
                                    SettingsFormRow(spec: spec)
                                }
                            }
                        }
                    }
                }
            }
            .settingsForm()
        }
    }

    private var visibleRows: [SettingsRowSpec] {
        let all = allRows
        guard !query.isEmpty else { return all.filter { $0.category == category } }
        let needle = query.lowercased()
        return all.filter { $0.searchText.contains(needle) }
    }

    private var allRows: [SettingsRowSpec] {
        var rows: [SettingsRowSpec] = [
            SettingsRowSpec(
                id: "present.mediaTransition", category: .present,
                title: "Media transition",
                caption: "Backgrounds and foreground media enter (and leave on Clear) with this unless the item sets its own. The footer chips adjust the same setting on the fly.",
                keywords: "transition dissolve fade blur media default cut clear background foreground",
                control: AnyView(DefaultTransitionControl(
                    kindKey: "transition.media.kind", durationKey: "transition.media.duration",
                    fallbackKind: TransitionKind.dissolve.rawValue, fallbackDuration: 0.7
                ))
            ),
            SettingsRowSpec(
                id: "present.slideTransition", category: .present,
                title: "Slide transition",
                caption: "How the slide layer changes between slides. Cut is the lyrics-safe default.",
                keywords: "transition dissolve fade slide default cut lyrics",
                control: AnyView(DefaultTransitionControl(
                    kindKey: "transition.slide.kind", durationKey: "transition.slide.duration",
                    fallbackKind: "", fallbackDuration: 0.5
                ))
            ),
            SettingsRowSpec(
                id: "present.defaultAnimations", category: .present,
                title: "Default animations",
                caption: "What Apply Default In / Apply Default Out write on the timeline's presence-bar ends. A preset's Set as Default In/Out changes it too.",
                keywords: "animation default in out fade timeline animate steps",
                control: AnyView(DefaultAnimationsControl(model: model))
            ),
            SettingsRowSpec(
                id: "present.continuous", category: .present,
                title: "Show whole plan",
                caption: "Every item's slides on one page, in plan order; arrows advance across items. Also in the View menu.",
                keywords: "scroll run order single item continuous playlist",
                control: AnyView(Toggle("", isOn: $continuousPresent).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.slidesAcross", category: .present,
                title: "Slides across",
                caption: "How many slide thumbnails share a row in Present — a fixed count, never a fit to the window or the sidebars.",
                keywords: "slide grid columns across per row thumbnails size zoom",
                control: AnyView(SlidesAcrossControl(count: $slidesAcross).frame(width: 190))
            ),
            SettingsRowSpec(
                id: "present.roundedCorners", category: .present,
                title: "Rounded thumbnail corners",
                caption: nil,
                keywords: "slide grid thumbnails corners",
                control: AnyView(Toggle("", isOn: $roundedCorners).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.legibleText", category: .present,
                title: "Readable thumbnail text",
                caption: "Boosts lyric legibility in thumbnails — never on the glass.",
                keywords: "slide grid lyrics legible text thumbnails",
                control: AnyView(Toggle("", isOn: $legibleText).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.transparencyGrid", category: .present,
                title: "Transparency grid in thumbnails",
                caption: "Checkerboard shows wherever nothing opaque covers the slide — where lower layers would show through on glass.",
                keywords: "transparency grid checkerboard alpha thumbnails photoshop",
                control: AnyView(Toggle("", isOn: $transparencyGrid).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.scopedBackgrounds", category: .present,
                title: "Backgrounds only on declaring slide",
                caption: "Thumbnails after the declaring slide drop the shared background.",
                keywords: "slide grid backgrounds cue thumbnails",
                control: AnyView(Toggle("", isOn: $hideScopedBackgrounds).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.nextSkipsBlanks", category: .present,
                title: "Confidence NEXT skips blank slides",
                caption: "Blank slides parked as clears are ignored — NEXT shows the first upcoming slide that has text.",
                keywords: "confidence monitor next blank empty slide stage skip",
                control: AnyView(Toggle("", isOn: Binding(
                    get: { nextSkipsBlanks },
                    set: {
                        nextSkipsBlanks = $0

                        controls?.refreshNextSlide()
                    }
                )).settingsToggle())
            ),
        ]
        if let layout {
            rows.append(SettingsRowSpec(
                id: "present.layouts", category: .present,
                title: "Present layouts",
                caption: "Save and switch whole workspace arrangements — panels, sizes, and windows (moved here from the footer).",
                keywords: "layout workspace arrangement save panels windows dock",
                control: AnyView(PresentLayoutMenuControl(layout: layout) { saved in
                    requestRunOnly(applying: saved)
                })
            ))
            rows.append(SettingsRowSpec(
                id: "present.runOnly", category: .present,
                title: "Simple Mode",
                caption: "The volunteer view: the plan, big slides, Back, Next and Clear All, with nothing that edits. Also in the main window's More menu. Leaving asks for the passcode.",
                keywords: "simple mode run only volunteer lock passcode pin kiosk",
                control: AnyView(HStack(spacing: 6) {
                    if layout.hasPIN {
                        Button("Change Passcode…") { pinFlow = .change }
                    }
                    Button("Enter Simple Mode…") { requestRunOnly(applying: nil) }
                })
            ))
        }
        rows.append(
            SettingsRowSpec(
                id: "screens.configuration", category: .screens,
                title: "Screen Configuration",
                caption: "The Audience, Livestream and Stage screens: which output carries each one, and its resolution.",
                keywords: "outputs displays screens audience livestream stage decklink ndi resolution 4k alpha key",
                control: AnyView(OpenScreenConfigurationButton())
            )
        )
        rows.append(SettingsRowSpec(
            id: "avInputs.cameras", category: .avInputs,
            title: "Video inputs",
            caption: "Added inputs run warm from launch and appear in Live Input pickers — slides never wait on a camera spinning up.",
            keywords: "camera capture device uvc continuity blackmagic live input video refresh",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "avInputs.audio", category: .avInputs,
            title: "Audio inputs",
            caption: "Interfaces and board feeds — each picks its device and channels. Live Assist listens to one of these.",
            keywords: "audio input microphone interface usb board feed sound source channels live assist",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "midi.devices", category: .midi,
            title: "MIDI devices",
            caption: "Devices MIDI talks to — each one can send, listen, or both, and switches off without being forgotten. With none added, MIDI Out reaches every destination on this Mac.",
            keywords: "midi device destination source input output port note control change iac lighting console enable disable direction",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "midi.lightkey", category: .midi,
            title: "Lightkey",
            caption: nil,
            keywords: "lightkey lighting dmx midi network rtp cue section verse chorus scene position walk-in countdown song message closing walkout baptism communion",
            control: AnyView(LightkeySettingsForm(model: model)),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "midi.map", category: .midi,
            title: "MIDI input map",
            caption: "What incoming notes trigger — clears, slides, videos, media, timers, alerts, macros. ProPresenter's stock numbers out of the box; every assignment is editable.",
            keywords: "midi input map note trigger command clear slide advance timer combo channel propresenter playlist media alert message select index",
            control: AnyView(MIDIMapManager())
        ))

        rows.append(SettingsRowSpec(
            id: "network.ndi", category: .api,
            title: "NDI network",
            caption: "The network NDI discovers and carries video on — inputs and screen outputs alike. Pin it to the wired production network when this Mac also joins Wi-Fi on another VLAN — even when both carry the same VLAN, the pin keeps NDI on the wire. Applies immediately; live feeds re-tune.",
            keywords: "ndi network interface adapter nic vlan ethernet wifi wired discovery pin bind",
            control: AnyView(NDINetworkScopeControl())
        ))
        if let controls {
            rows.append(SettingsRowSpec(
                id: "show.screens", category: .showSetup,
                title: "Screens",
                caption: nil,
                keywords: "audience livestream stream stage display confidence screen monitor output decklink ndi resolution 4k 1080p alpha key lower third transparent full screen stage message seconds clear",
                control: AnyView(ShowSetupForm(controls: controls)),
                stacked: true
            ))
        }
        if let model {
            rows.append(SettingsRowSpec(
                id: "show.typeScreens", category: .showSetup,
                title: "Lower Thirds",
                caption: nil,
                keywords: "lower third lower thirds theme worship message sermon scripture bible announcements livestream stream type default series song",
                control: AnyView(ScreensByTypeForm(model: model, render: controls?.render)),
                stacked: true
            ))
        }
        if controls != nil {
            rows.append(SettingsRowSpec(
                id: "show.decklink", category: .showSetup,
                title: "Blackmagic DeckLink",
                caption: nil,
                keywords: "decklink blackmagic sdi ultrastudio desktop video output card 8k duo quad",
                control: AnyView(DeckLinkSetupForm()),
                stacked: true
            ))
        }
        rows.append(SettingsRowSpec(
            id: "show.liveAssist", category: .showSetup,
            title: "Live Assist",
            caption: nil,
            keywords: "live assist lyric following speech microphone scripture detection auto advance",
            control: AnyView(LiveAssistSettingsForm()),
            stacked: true
        ))
        if let model {
            rows.append(SettingsRowSpec(
                id: "bible.sermon", category: .bible,
                title: "Sermon import",
                caption: "Claude reads the week's notes (PDF or Pages) and builds the message slides with the series theme.",
                keywords: "sermon notes import claude anthropic api key series theme message slides pdf pages",
                control: AnyView(SermonImportSettingsForm(model: model)),
                stacked: true
            ))
            rows.append(SettingsRowSpec(
                id: "api.assistant", category: .api,
                title: "Assistant",
                caption: "Window › Assistant (⇧⌘A) answers questions about Screens and makes changes to plans and slides with Claude.",
                keywords: "assistant claude anthropic api key model opus sonnet ai chat help pre-service announcements events",
                control: AnyView(AssistantSettingsForm()),
                stacked: true
            ))
            rows.append(SettingsRowSpec(
                id: "bible.themes", category: .bible,
                title: "Scripture and points themes",
                caption: "Used by the Scripture and Points buttons in the top bar.",
                keywords: "scripture bible points sermon theme default template",
                control: AnyView(Form { ScriptureThemeSetting(model: model) }.formStyle(.columns)),
                stacked: true
            ))
            rows.append(SettingsRowSpec(
                id: "present.types", category: .present,
                title: "Presentation types",
                caption: "Default actions for each type of presentation, run when one goes live — stage layout and timers.",
                keywords: "presentation type category sermon worship bible announcement default action stage layout timer",
                control: AnyView(PresentationTypeRulesForm(model: model)),
                stacked: true
            ))
        }
        rows.append(SettingsRowSpec(
            id: "anthem.link", category: .shepherd,
            title: "Anthem",
            caption: "Anthem leads: the tracks change the slides, and each song's order follows Anthem's setlist.",
            keywords: "anthem tracks multitrack cue slides network propresenter band setlist arrangement order section match midi",
            control: AnyView(AnthemSettingsForm()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "shepherd.sync", category: .shepherd,
            title: "Shepherd",
            caption: "Upcoming Sunday plans from Shepherd become services. Songs link to presentations already in the library; any without one are flagged No slides.",
            keywords: "shepherd hope plan sunday service sync song flag api key",
            control: AnyView(ShepherdSettingsForm()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "bible.sources", category: .bible,
            title: "Bible translations",
            caption: "Where scripture text comes from. Type a reference in Scripture Slides (File menu) and slides are built with your Bible template — each slide starts at the beginning of a verse.",
            keywords: "bible scripture translation esv niv kjv nlt api verse passage key",
            control: AnyView(BibleSettingsForm()),
            stacked: true
        ))
        rows.append(contentsOf: apiRows)
        return rows
    }

    private var apiRows: [SettingsRowSpec] {
        guard let api else { return [] }
        return [
            SettingsRowSpec(
                id: "api.enabled", category: .api,
                title: "Local API",
                caption: "Serves the documented REST + WebSocket API on this Mac and announces it on the local network.",
                keywords: "api rest websocket http server remote companion stream deck automation bonjour",
                control: AnyView(LocalAPIEnableToggle(api: api))
            ),
            SettingsRowSpec(
                id: "api.port", category: .api,
                title: "Port",
                caption: "Changing the port restarts the server.",
                keywords: "api port number network",
                control: AnyView(LocalAPIPortField(api: api))
            ),

            SettingsRowSpec(
                id: "api.address", category: .api,
                title: "Connect at",
                caption: "Phone & tablet remote: open http://<this address>/ in Safari or Chrome on the same Wi-Fi and paste a Control access key from the row below. Companion and Stream Deck use the same address.",
                keywords: "api address ip port connect companion stream deck remote host default key",
                control: AnyView(LocalAPIAddressRow(api: api))
            ),
            SettingsRowSpec(
                id: "api.remote", category: .api,
                title: "Phone remote",
                caption: "Scan with a phone or iPad on the same Wi-Fi. It opens the remote: the booth's Back and Next with the slides as pictures, or the stage's sermon timer and notes to the booth.",
                keywords: "remote phone iphone ipad qr code scan pastor worship leader booth message home screen",
                control: AnyView(LocalAPIRemoteQRRow(api: api)),
                stacked: true
            ),
            SettingsRowSpec(
                id: "api.tokens", category: .api,
                title: "Access keys",
                caption: "Required — nothing connects without one. Create a key here and paste it into the client. Each key grants Watch, Operate, or Manage access.",
                keywords: "api tokens keys auth bearer secret scope watch operate manage revoke password required",
                control: AnyView(LocalAPITokensButton(api: api))
            ),
            SettingsRowSpec(
                id: "api.docs", category: .api,
                title: "API reference",
                caption: "A browsable page of every endpoint with descriptions and copyable examples — served by this Mac, works offline.",
                keywords: "api reference docs documentation openapi explorer examples endpoints developer",
                control: AnyView(LocalAPIContractRow(api: api))
            ),
        ]
    }


}

enum SettingsCategory: String, CaseIterable, Identifiable {

    case appearance
    case showSetup
    case present

    case avInputs
    case midi

    case keyboard
    case screens
    case bible
    case shepherd
    case api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .showSetup: "Show Setup"
        case .present: "Present"
        case .avInputs: "Audio/Video Inputs"
        case .midi: "MIDI"
        case .keyboard: "Keyboard"
        case .screens: "Screens"
        case .bible: "Bible"
        case .shepherd: "Shepherd & Anthem"

        case .api: "Network & API"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .showSetup: "rectangle.3.group"
        case .present: "play.rectangle"
        case .avInputs: "camera"
        case .midi: "pianokeys"
        case .keyboard: "keyboard"
        case .screens: "display"
        case .bible: "book"
        case .shepherd: "calendar.badge.clock"
        case .api: "network"
        }
    }
}

@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var pending: SettingsCategory?
    private init() {}
}

struct SettingsRowSpec: Identifiable {
    let id: String
    let category: SettingsCategory
    let title: String
    let caption: String?
    let keywords: String
    let control: AnyView

    var stacked: Bool = false

    var searchText: String {
        "\(title) \(caption ?? "") \(keywords) \(category.title)".lowercased()
    }
}

private struct SettingsRowView: View {
    let spec: SettingsRowSpec

    var body: some View {

        Group {
            if spec.stacked {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    spec.control
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    header
                    Spacer(minLength: 16)
                    spec.control
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title)
                .font(.system(size: 11, weight: .medium))
            if let caption = spec.caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OpenScreenConfigurationButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open\u{2026}") {
            openWindow(id: "outputs")
        }
    }
}

private struct PresentLayoutMenuControl: View {
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
            HStack(spacing: 3) {
                Text(active?.name ?? "Layouts")
                    .font(.system(size: 10))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
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

extension Toggle {

    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .labelsHidden()
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
            .fixedSize()
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
            .fixedSize()
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
        HStack(spacing: 10) {
            Picker("", selection: storedKind) {
                Text("Cut").tag("")
                Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
            }
            .labelsHidden()
            .fixedSize()
            if !kindRaw.isEmpty {
                Stepper(
                    String(format: "%.2gs", duration),
                    value: storedDuration, in: 0 ... 5, step: 0.1
                )
                .font(.caption.monospacedDigit())
                .controlSize(.small)
            }
        }
    }
}
