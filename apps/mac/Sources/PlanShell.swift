import PresenterCore
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// The main window: the plans (or the library) above the chosen plan's
/// items, the slides, and every screen's preview. In Present and Schedule
/// the plan and the screens are panels that fold away to give the slides
/// the room (see ShellPanel): the plan to a bubble at the top left, the
/// screens to a strip of tiny previews at the top right, each opening on
/// hover and docking beside the slides on a click. Clear All, the sermon
/// time and the microphone sit in a bar over the slides either way. Edit
/// keeps the split view's own sidebar.
struct PlanShell: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    @AppStorage("appMode") private var modeRaw = AppMode.present.rawValue
    @AppStorage(ShellPanel.Side.plans.defaultsKey) private var planPinnedStored = ShellPanel.Side.plans.pinnedByDefault
    @AppStorage(ShellPanel.Side.screens.defaultsKey) private var screensPinnedStored = ShellPanel.Side.screens.pinnedByDefault
    @State private var planPanel = ShellPanel(pinned: ShellPanel.Side.plans.storedPinned(in: .standard))
    @State private var screensPanel = ShellPanel(pinned: ShellPanel.Side.screens.storedPinned(in: .standard))
    /// The screens hidden from the column (its eye menu); the strip leaves them out too.
    @AppStorage("monitors.hidden") private var hiddenScreens = ""
    @AppStorage("shell.topPane") private var topPane = TopPane.plans
    /// View › Show Whole Plan: Present shows every item's slides on one
    /// scrolling page, in order; off, just the selected item's.
    @AppStorage(Self.wholePlanKey) private var showWholePlan = true
    @State private var itemID: String?
    /// Whether the page has already scrolled to the selected item, so a
    /// selection that came from the page itself doesn't jump it.
    @State private var presentFocusScroll = PresentFocusScroll()
    /// The bottom bar's room, measured: what fits beside the control bar.
    @State private var bottomBarWidth: CGFloat = 0
    /// The split view's own sidebar is Edit's; Present and Schedule start
    /// with it folded, so it doesn't flash open on launch.
    @State private var columns: NavigationSplitViewVisibility =
        UserDefaults.standard.string(forKey: "appMode") == AppMode.edit.rawValue ? .all : .detailOnly
    @State private var creatingPlan = false
    @State private var controlsShown = false
    @State private var addingVideo = false
    /// Songs open in the song editor; this switches to the slide editor.
    @State private var songSlideEditor = false
    @State private var messagePlanID: String?
    @State private var themeFromImage = false
    @State private var scriptureShown = false
    /// The plan whose message notes are being imported.
    @State private var notesPlanID: String?
    @State private var schedulePlanID: String?
    /// The plan being saved as a template, while its message length is asked.
    @State private var templatePlanID: String?
    @State private var simpleModePIN: PinFlow?
    @State private var confirmingSimpleMode = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared with Settings › Present and the View menu.
    static let wholePlanKey = "present.continuous"

    enum TopPane: String { case plans, library }

    @Environment(\.confidenceMonitor) private var confidenceMonitor

    private var workspaceImportAction: MenuAction? {
        guard let render, let controls else { return nil }
        return MenuAction("workspaceImport") {
            WorkspaceImportRunner(
                model: model, render: render, controls: controls,
                confidenceMonitor: confidenceMonitor
            ).present()
        }
    }

    private var findInLibraryAction: MenuAction? {
        runOnly ? nil : MenuAction("findInLibrary") {
            topPane = .library
            model.libraryFindPending = true
        }
    }

    private static let presentNewSlideAction = MenuAction("presentNewSlide") {
        NewSlideRouter.shared.request()
    }

    private var mode: AppMode { AppMode(rawValue: modeRaw) ?? .present }
    private var runOnly: Bool { layout?.runOnly ?? false }

    var body: some View {
        face
            .sheet(item: Binding(get: { messagePlanID.map(IdentifiedID.init) }, set: { messagePlanID = $0?.id })) { plan in
                PlanMessageSheet(model: model, planID: plan.id)
            }
            .sheet(item: Binding(get: { notesPlanID.map(IdentifiedID.init) }, set: { notesPlanID = $0?.id })) { plan in
                SermonImportSheet(model: model, planID: plan.id)
            }
            .sheet(item: Binding(get: { templatePlanID.map(IdentifiedID.init) }, set: { templatePlanID = $0?.id })) { item in
                if let plan = model.resident.services.value(item.id) {
                    SermonLengthPrompt(initialMinutes: TemplateSermonLength.suggestedMinutes(for: plan, model: model)) { minutes in
                        saveTemplate(from: plan, sermonSeconds: SermonTimer.seconds(minutes: minutes))
                    }
                }
            }
            .sheet(item: Binding(get: { schedulePlanID.map(IdentifiedID.init) }, set: { schedulePlanID = $0?.id })) { plan in
                ScheduleServiceSheet(model: model, planID: plan.id)
            }
            .sheet(isPresented: $scriptureShown) {
                ScriptureSheet(model: model, render: render) { id in addToPlan(id) }
            }
            .sheet(isPresented: $creatingPlan) {
                NewServiceSheet(model: model) { id in model.currentServiceID = id }
            }
            .sheet(isPresented: $controlsShown) {
                if let controls {
                    ShowControlsPanel(model: model, controls: controls)
                        .frame(width: 380, height: 480)
                        .safeAreaInset(edge: .bottom) {
                            HStack { Spacer(); Button("Done") { controlsShown = false }.keyboardShortcut(.defaultAction) }
                                .padding(12)
                        }
                }
            }
            .fileImporter(isPresented: $addingVideo, allowedContentTypes: [.movie, .video, .image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await addMedia(urls) }
            }
            .animation(HopeMotion.ui(reduced: reduceMotion), value: model.currentServiceID)
            .onChange(of: model.currentServiceID) { _, _ in
                itemID = nil
                presentFocusScroll.reset()
                ensureCountdowns()
            }
            // Coming back to Present (or to the whole plan) lands on the
            // selected item again.
            .onChange(of: modeRaw) { _, _ in presentFocusScroll.reset() }
            .onChange(of: showWholePlan) { _, _ in presentFocusScroll.reset() }
            .onChange(of: plans.upcoming.map(\.id)) { ensureCountdowns() }
            .onChange(of: itemID) { _, _ in songSlideEditor = false }
            .task {
                await model.resident.ready([.service])
                ensureCountdowns()
                // A plan remembered from a library that's since been wiped.
                if let id = model.currentServiceID, model.resident.services.value(id) == nil {
                    model.currentServiceID = nil
                }
            }
    }

    /// Simple Mode (the run-only lock) swaps the whole workspace for the
    /// volunteer view; everything from here down serves both.
    private var face: some View {
        Group {
            if runOnly {
                SimpleModeView(model: model, render: render, controls: controls, layout: layout)
            } else {
                themeRouted
            }
        }
        // Notes from the phone remote's stage view, over either face.
        .overlay(alignment: .top) { BoothMessageBanner() }
        .tint(HopeStyle.blue)
        .preferredColorScheme(.dark)
        // The menu bar's commands (File › New, Import, the Present menu, …)
        // find the library and the show through these.
        .focusedSceneValue(\.libraryModel, model)
        .focusedSceneValue(\.serviceControls, controls)
        .focusedSceneValue(\.presentWorkspaceImport, runOnly ? nil : workspaceImportAction)
        .focusedSceneValue(\.presentLibrarySearch, findInLibraryAction)
        .focusedSceneValue(\.presentNewSlide, mode == .present && !runOnly ? Self.presentNewSlideAction : nil)
        .focusedSceneValue(\.presentScripture, runOnly ? nil : MenuAction("scripture") { scriptureShown = true })
        .focusedSceneValue(\.presentSimpleMode, runOnly || layout == nil ? nil : MenuAction("simpleMode") { requestSimpleMode() })
        .environment(\.runOnly, runOnly)
        .sheet(item: $simpleModePIN) { flow in
            // The first time only: the passcode that will let someone out again.
            PasscodeSheet(flow: flow, verify: { _ in false }) { pin in
                layout?.setPIN(pin)
                layout?.enterRunOnly()
            }
        }
        .confirmationDialog("Switch to Simple Mode?", isPresented: $confirmingSimpleMode) {
            Button("Simple Mode") { layout?.enterRunOnly() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Volunteers can run the slides but not change anything. Leaving Simple Mode asks for the passcode.")
        }
    }

    /// The full app: plans and library, the slides, every screen.
    private var workspace: some View {
        // Every column gets a fixed minimum and is free to shrink inside it:
        // content that reports its own changing minimum size makes the split
        // view re-run constraints forever, and AppKit then ends the app.
        NavigationSplitView(columnVisibility: $columns) {
            // Narrow like ProPresenter's: the library's tab row folds extra
            // tabs into its ··· menu, so 180 is enough. Only Edit uses this
            // column; Present and Schedule have the plan panel instead, so
            // nothing is built here for them.
            Group {
                if mode == .edit { sidebar } else { Color.clear }
            }
            .frame(minWidth: 180, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 360)
            .toolbar(removing: mode == .edit ? nil : .sidebarToggle)
        } detail: {
            // The docked panels sit beside the slides at fixed widths in a
            // plain HStack rather than as split-view columns or an inspector:
            // next to a two-column split, an inspector's size negotiation
            // never settles and AppKit ends the app. Folded and peeking, they
            // float over the slides and take no room from them.
            HStack(spacing: 0) {
                if panelsShown && planPanel.isPinned {
                    dockedPlanPanel
                        .frame(width: ShellMetrics.planWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                slidesArea
                if panelsShown && screensPanel.isPinned, let render {
                    Divider()
                    screensColumn(render, pinned: true)
                        .frame(width: ShellMetrics.screensWidth)
                        .frame(maxHeight: .infinity)
                        .dockedPanel()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background { ShellBackdrop() }
            // Edit folds the left column away so the slide canvas gets the
            // room; Present and Schedule bring it back.
            .onChange(of: modeRaw, initial: true) {
                syncSidebar()
                planPanel.dismissPeek()
                screensPanel.dismissPeek()
            }
            .onChange(of: itemID) { syncSidebar() }
            .onChange(of: model.selectedEntryID) { syncSidebar() }
            .onChange(of: planPanel.isPinned) { _, pinned in planPinnedStored = pinned }
            .onChange(of: screensPanel.isPinned) { _, pinned in screensPinnedStored = pinned }
            .onChange(of: planPinnedStored) { _, pinned in planPanel.setPinned(pinned) }
            .onChange(of: screensPinnedStored) { _, pinned in screensPanel.setPinned(pinned) }
            .navigationTitle(model.currentServiceID.flatMap { model.resident.services.value($0)?.name } ?? "Screens")
        }
        .toolbar { toolbar }
        // View › Pin Plan / Pin Screens and their shortcuts.
        .focusedSceneValue(\.planPanelToggle, panelsShown ? MenuAction("planPanel") { togglePanel(.plans) } : nil)
        .focusedSceneValue(\.screensPanelToggle, screensMenuShown ? MenuAction("screensPanel") { togglePanel(.screens) } : nil)
    }

    // MARK: Panels (Present and Schedule)

    /// Edit gives the editor the room; Present and Schedule have the panels.
    private var panelsShown: Bool { mode != .edit }
    private var screensMenuShown: Bool { panelsShown && render != nil }
    private var planFloats: Bool { panelsShown && !planPanel.isPinned }
    private var screensFloat: Bool { screensMenuShown && !screensPanel.isPinned }

    /// The View menu, its shortcut, or a toolbar button.
    private func togglePanel(_ side: ShellPanel.Side) {
        withAnimation(HopeMotion.ui(reduced: reduceMotion)) {
            switch side {
            case .plans: planPanel.toggle()
            case .screens: screensPanel.toggle()
            }
        }
    }

    /// The bubble, the strip, or a panel's pin.
    private func clickPanel(_ side: ShellPanel.Side) {
        let now = ProcessInfo.processInfo.systemUptime
        withAnimation(HopeMotion.ui(reduced: reduceMotion)) {
            switch side {
            case .plans: planPanel.click(at: now)
            case .screens: screensPanel.click(at: now)
            }
        }
    }

    /// The slides, with the floating pieces over them: the bubble, the
    /// strip and their peeking cards, and the control bar.
    private var slidesArea: some View {
        center
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .animation(HopeMotion.ui(reduced: reduceMotion), value: modeRaw)
            // The whole-plan page scrolls to an item instead of
            // swapping views, and its selection moves as it scrolls.
            .animation(HopeMotion.ui(reduced: reduceMotion), value: wholePlanShown ? nil : itemID)
            // Room at the top for the bubble and the strip, so the first row
            // of slides isn't under them; the page scrolls up beneath.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: ShellMetrics.band(planFloats: planFloats, screensFloat: screensFloat))
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .overlay(alignment: .topLeading) {
                if planFloats { planFloat }
            }
            .overlay(alignment: .topTrailing) {
                if screensFloat, let render { screensFloatView(render) }
            }
            // Listening is never a secret: a red bar across the top
            // of the slides for as long as a microphone is open.
            .safeAreaInset(edge: .top, spacing: 0) { LiveListeningBar() }
            .animation(HopeMotion.ui(reduced: reduceMotion), value: LiveAssist.shared.listening)
            .animation(HopeMotion.ui(reduced: reduceMotion), value: planPanel.mode)
            .animation(HopeMotion.ui(reduced: reduceMotion), value: screensPanel.mode)
    }

    /// The control bar centred under the slides, and in Present the slide
    /// size at the right. On a clear background: the page scrolls beneath.
    /// What fits is decided from the measured width of the slides, not by
    /// trying layouts, so a resize can't make it flip back and forth.
    @ViewBuilder
    private var bottomBar: some View {
        if panelsShown {
            let sizeWanted = mode == .present && model.currentServiceID != nil
            let side = SlideSizeControl.width + 8
            let sizeShown = sizeWanted && bottomBarWidth >= ShowControlBar.width + side
            let balanced = sizeShown && bottomBarWidth >= ShowControlBar.width + side * 2
            HStack(spacing: 8) {
                // Balances the slide size control, so the bar stays centred.
                if balanced { Color.clear.frame(width: SlideSizeControl.width, height: 1) }
                Spacer(minLength: 0)
                if let controls { ShowControlBar(controls: controls) }
                Spacer(minLength: 0)
                if sizeShown { SlideSizeControl().glassChip() }
            }
            .padding(.horizontal, ShellMetrics.inset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - ShellMetrics.inset * 2 } action: { width in
                let rounded = (width / 8).rounded(.down) * 8
                if rounded != bottomBarWidth { bottomBarWidth = rounded }
            }
        }
    }

    // MARK: The plan panel

    private var currentPlan: Service? {
        model.currentServiceID.flatMap { model.resident.services.value($0) }
    }

    /// The item the show is on, else the one chosen in the list.
    private var currentItem: ServiceItem? {
        guard let plan = currentPlan else { return nil }
        if let live = controls?.liveContextID, let item = plan.items.first(where: { $0.id == live }) {
            return item
        }
        return itemID.flatMap { id in plan.items.first { $0.id == id } }
    }

    private func planHandle(pinned: Bool) -> PlanBubbleLabel {
        let item = currentItem
        return PlanBubbleLabel(
            planName: currentPlan?.name,
            itemName: item.map { $0.name.isEmpty ? "Untitled" : $0.name },
            kind: item.map { HopeStyle.kind(of: $0, presentation: $0.itemKind == .presentation ? model.presentation($0.refId) : nil) },
            pinned: pinned)
    }

    /// The bubble when folded, the whole panel when peeking: one view, so
    /// the pointer stays inside it while the one becomes the other.
    private var planFloat: some View {
        ZStack(alignment: .topLeading) {
            if planPanel.isPeeking {
                VStack(spacing: 0) {
                    planHeaderButton(pinned: false)
                    Divider()
                    sidebar
                }
                .frame(width: ShellMetrics.planWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .peekCard()
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            } else {
                Button { clickPanel(.plans) } label: {
                    planHandle(pinned: false)
                        .padding(.horizontal, 12)
                        .frame(width: 236, height: ShellMetrics.bubbleHeight)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .help("The plan. Point at it to look, click to keep it open (⌃⌘S).")
                .transition(.opacity)
            }
        }
        .modifier(ShellPanelHover(panel: $planPanel))
        .padding(ShellMetrics.inset)
    }

    private func planHeaderButton(pinned: Bool) -> some View {
        Button { clickPanel(.plans) } label: {
            planHandle(pinned: pinned)
                .padding(.horizontal, 12)
                .frame(height: ShellMetrics.bubbleHeight)
        }
        .buttonStyle(.plain)
        .help(pinned ? "Fold the plan to a bubble (⌃⌘S)" : "Keep the plan open beside the slides (⌃⌘S)")
    }

    private var dockedPlanPanel: some View {
        VStack(spacing: 0) {
            planHeaderButton(pinned: true)
            Divider()
            sidebar
        }
        .dockedPanel()
    }

    // MARK: The screens panel

    private func screensColumn(_ render: RenderContext, pinned: Bool) -> some View {
        MonitorsPanel(
            render: render, liveKey: controls?.liveSlideID,
            onPin: { clickPanel(.screens) }, pinned: pinned,
            controls: controls,
            onEditStage: { editStageDisplay() })
    }

    /// The strip when folded, the whole column when peeking.
    private func screensFloatView(_ render: RenderContext) -> some View {
        ZStack(alignment: .topTrailing) {
            if screensPanel.isPeeking {
                screensColumn(render, pinned: false)
                    .frame(width: ShellMetrics.screensWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .peekCard()
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            } else {
                // Built only while folded: the full previews aren't drawn at all then.
                Button { clickPanel(.screens) } label: {
                    ScreensStrip(
                        render: render, controls: controls,
                        screens: MonitorsPanel.shownScreens(render: render, setup: ShowSetup.shared, hiddenList: hiddenScreens))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .help("The screens. Point at them to look, click to keep them open (⌃⌘R).")
                .transition(.opacity)
            }
        }
        .modifier(ShellPanelHover(panel: $screensPanel))
        .padding(ShellMetrics.inset)
    }

    /// Simple Mode from the toolbar or View menu: the first time sets the
    /// passcode (the same one Settings › Run-Only uses), after that it asks
    /// once so a stray click doesn't lock the booth.
    private func requestSimpleMode() {
        guard let layout else { return }
        if layout.hasPIN {
            confirmingSimpleMode = true
        } else {
            simpleModePIN = .set
        }
    }

    // MARK: Sidebar — plans or the library, then the plan's items

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !runOnly {
                topPaneHeader
                Group {
                    switch topPane {
                    case .plans: planList
                    case .library: LibrarySidebar(model: model, render: render, layout: layout, controls: controls)
                    }
                }
                .frame(height: topPane == .plans ? 210 : 300)
                Divider()
            }
            planItems
                .frame(maxHeight: .infinity)

            // Saved live inputs wait for the microphone answer; Screens never
            // raises the prompt by itself (see AudioInputInventory).
            if AudioInputInventory.shared.needsMicrophoneAccess {
                MicrophoneAccessBanner()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .transition(.opacity)
            }
        }
    }

    private var topPaneHeader: some View {
        HStack(spacing: 6) {
            Picker("Show", selection: $topPane.animation(HopeMotion.ui(reduced: reduceMotion))) {
                Text("Plans").tag(TopPane.plans)
                Text("Library").tag(TopPane.library)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            if topPane == .plans {
                Button { creatingPlan = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New plan")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var planList: some View {
        List(selection: Binding(
            get: { model.currentServiceID },
            set: { if let id = $0 { model.currentServiceID = id } }
        )) {
            Section("Upcoming") {
                ForEach(plans.upcoming, id: \.id) {
                    planRow($0).transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                }
                if plans.upcoming.isEmpty {
                    Text("Nothing planned yet").foregroundStyle(.secondary)
                }
            }
            if !plans.templates.isEmpty {
                Section("Templates") {
                    ForEach(plans.templates, id: \.id) { planRow($0) }
                }
            }
            if !plans.past.isEmpty {
                Section("Past") {
                    ForEach(plans.past, id: \.id) { planRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .font(.system(size: 12))
        .environment(\.defaultMinListRowHeight, 22)
    }

    private func planRow(_ plan: Service) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(plan.name).lineLimit(1)
            if plan.isTemplate != true, let date = Self.dateLabel(plan.serviceDate) {
                HStack(spacing: 4) {
                    if plan.id == plans.upcoming.first?.id {
                        NextTag()
                    }
                    Text(date).font(.caption).foregroundStyle(HopeStyle.lightBlue)
                }
            }
        }
        .tag(plan.id)
        .contextMenu {
            if !runOnly {
                if plan.isTemplate == true {
                    Button("New Plan from This Template") { newPlan(from: plan) }
                    Button("Stop Using as Template") { model.updateService(plan.id) { $0.isTemplate = nil } }
                } else {
                    Button("Save as Template…") {
                        if TemplateSermonLength.hasMessage(plan, model: model) {
                            templatePlanID = plan.id
                        } else {
                            saveTemplate(from: plan, sermonSeconds: nil)
                        }
                    }
                }
            }
        }
    }

    /// A template copy of a plan: the same order, headers and colors, with
    /// links to the same presentations; a message stays a placeholder.
    private func saveTemplate(from plan: Service, sermonSeconds: Double?) {
        var template = plan
        template.id = UUID().uuidString
        template.name = plan.name + " Template"
        template.isTemplate = true
        template.origin = nil
        template.mxuPlanHexId = nil
        template.mxuPlanVersion = nil
        template.mxuPlanTimes = nil
        template.items = plan.items.map { item in
            var copy = item
            copy.id = UUID().uuidString
            return copy
        }
        // The one thing each template sets for its stage: how long the message runs.
        if let sermonSeconds { TemplateSermonLength.apply(sermonSeconds, to: &template, model: model) }
        model.createInDrive(template)
    }

    /// Next Sunday's plan from a template. Each plan gets a message of its
    /// own (empty, in the template's series) instead of sharing one.
    private func newPlan(from template: Service) {
        var plan = template
        plan.id = UUID().uuidString
        plan.isTemplate = nil
        plan.name = template.name.replacingOccurrences(of: " Template", with: "")
        plan.serviceDate = Self.dayFormatter.string(from: NewServiceSheet.nextSunday())
        plan.messagePresentationId = nil
        plan.items = template.items.map { item in
            var copy = item
            copy.id = UUID().uuidString
            if item.refId == template.messagePresentationId
                || (item.itemKind == .presentation && model.presentation(item.refId)
                    .map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true) {
                var message = Presentation(
                    id: UUID().uuidString, name: "Message", presentationKind: .deck,
                    themeId: template.sermonThemeId ?? model.slideBuilding.sermonThemeId ?? BasicTemplates.pointsThemeID,
                    slides: [])
                message.category = PresentationTypes.sermon
                message.sermonTimerSeconds = TemplateSermonLength.seconds(in: template, model: model)
                model.createInDrive(message)
                copy.refId = message.id
                plan.messagePresentationId = message.id
            }
            return copy
        }
        model.createInDrive(plan)
        model.currentServiceID = plan.id
    }

    /// Upcoming plans soonest first, templates, then past plans newest first.
    private var plans: (upcoming: [Service], templates: [Service], past: [Service]) {
        let today = Self.dayFormatter.string(from: .now)
        let everything = Array(model.resident.services.values)
        let templates = everything.filter { $0.isTemplate == true }.sorted { $0.name < $1.name }
        let all = everything.filter { $0.isTemplate != true }
        let upcoming = all.filter { ($0.serviceDate ?? "") >= today || $0.serviceDate == nil }
            .sorted { ($0.serviceDate ?? "9999", $0.name) < ($1.serviceDate ?? "9999", $1.name) }
        let past = all.filter { ($0.serviceDate ?? "9999") < today }
            .sorted { ($0.serviceDate ?? "", $0.name) > ($1.serviceDate ?? "", $1.name) }
        return (upcoming, templates, past)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dateLabel(_ day: String?) -> String? {
        guard let day, let date = dayFormatter.date(from: day) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: The plan's items

    @ViewBuilder
    private var planItems: some View {
        if let planID = model.currentServiceID, let plan = model.resident.services.value(planID) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(plan.name.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !runOnly {
                        Button { messagePlanID = planID } label: { Image(systemName: "text.book.closed") }
                            .buttonStyle(.borderless)
                            .help("This plan's message, sermon series and what every screen shows")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                RunOrderList(
                    model: model, controls: controls, serviceID: planID, render: render,
                    selectedItemID: $itemID,
                    // Clicking the item already selected scrolls back to it.
                    onReselect: { if wholePlanShown { presentFocusScroll.reselect() } },
                    planAdds: PlanAddActions(
                        song: { addPresentation(planID, kind: .song) },
                        deck: { addPresentation(planID, kind: .deck) },
                        slideshow: { addPresentation(planID, kind: .slideshow) },
                        media: { addingVideo = true },
                        message: { notesPlanID = planID }))
            }
        } else {
            HopeEmptyState(title: "No Plan", symbol: "list.bullet.rectangle.portrait",
                           message: "Choose a plan above, or make a new one.") {
                if !runOnly {
                    Button("New Plan", systemImage: "plus") { creatingPlan = true }
                        .buttonStyle(.glassProminent)
                        .tint(HopeStyle.blue)
                }
            }
        }
    }

    // MARK: Center

    @ViewBuilder
    private var center: some View {
        switch mode {
        case .present:
            if let planID = model.currentServiceID {
                Group {
                    if showWholePlan {
                        // No background of its own: the window's backdrop shows through.
                        ServiceContinuousView(
                            model: model, render: render, controls: controls,
                            serviceID: planID, focusItemID: itemID,
                            focusScroll: $presentFocusScroll,
                            onShowItem: { showItem($0) })
                            // A new plan starts at its top.
                            .id(planID)
                    } else {
                        ServiceItemDetailView(
                            model: model, render: render, controls: controls, serviceID: planID, itemID: itemID)
                    }
                }
            } else {
                HopeEmptyState(title: "Nothing to Show", symbol: "sparkles.rectangle.stack",
                               message: "Pick a plan in the plan panel.")
            }
        case .edit:
            editor
        case .scheduler:
            SchedulerView(model: model, controls: controls)
        }
    }

    private var wholePlanShown: Bool { mode == .present && showWholePlan }

    /// The page scrolled to this item by itself (the operator's scroll, or
    /// following the live slide): highlight it in the list without a jump.
    private func showItem(_ id: String) {
        guard wholePlanShown, itemID != id else { return }
        presentFocusScroll.follow(id)
        itemID = id
    }

    @ViewBuilder
    private var editor: some View {
        if let refID = selectedRefID, let entry = model.indexEntry(refID) {
            switch entry.kind {
            case .presentation where !songSlideEditor && model.presentation(entry.id)?.presentationKind == .song:
                SongEditorView(model: model, presentationID: entry.id) { songSlideEditor = true }
                    .id(entry.id)
            case .presentation, .theme, .overlay, .confidenceLayout:
                SlideEditorView(
                    appModel: model, render: render, presentationID: entry.id,
                    isTheme: entry.kind == .theme, isOverlay: entry.kind == .overlay,
                    isConfidenceLayout: entry.kind == .confidenceLayout)
                    .id("\(entry.id)::\(model.importReplaceVersion)")
            case .media, .audio:
                MediaEditorView(model: model, entry: entry).id(entry.id)
            default:
                InspectorView(model: model, entry: entry).frame(maxWidth: 560)
            }
        } else {
            HopeEmptyState(title: "Nothing to Edit", symbol: "pencil.and.scribble",
                           message: "Pick an item in the plan, or something in the library.",
                           colors: [HopeStyle.amber, HopeStyle.stagePurple])
        }
    }

    /// The split view's sidebar is Edit's alone, and Edit folds it away when
    /// something is open, so the slide canvas gets the room. Present and
    /// Schedule keep it folded: their plan is the plan panel. `columns` only
    /// reads the state: setting it grew the window by the column's width
    /// each time the column came back, while the split view's own toggle
    /// doesn't.
    private func syncSidebar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let fold = mode != .edit || selectedRefID != nil
            let hidden = columns == .detailOnly
            guard fold != hidden else { return }
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
    }

    /// The plan item chosen, else the library item chosen.
    private var selectedRefID: String? {
        if let planID = model.currentServiceID, let itemID,
           let item = model.resident.services.value(planID)?.items.first(where: { $0.id == itemID }), !item.refId.isEmpty {
            return item.refId
        }
        return model.selectedEntryID
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if panelsShown {
                Button { togglePanel(.plans) } label: {
                    Label(planPanel.isPinned ? "Fold Plan" : "Pin Plan", systemImage: "sidebar.left")
                }
                .help(planPanel.isPinned ? "Fold the plan to a bubble (⌃⌘S)" : "Keep the plan open beside the slides (⌃⌘S)")
            }
        }
        ToolbarItem(placement: .principal) {
            if !runOnly {
                Picker("Mode", selection: $modeRaw) {
                    Text("Present").tag(AppMode.present.rawValue)
                    Text("Edit").tag(AppMode.edit.rawValue)
                    Text("Schedule").tag(AppMode.scheduler.rawValue)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !runOnly {
                Button {
                    schedulePlanID = model.currentServiceID
                } label: {
                    Label("Schedule Service", systemImage: "calendar.badge.clock")
                }
                .disabled(model.currentServiceID == nil)
                .help("When this service starts and when its countdown starts")
                bibleMenu
                Button { openWindow(id: "assistant") } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help("Assistant (⇧⌘A)")
            }
            // Everything not used every minute of a service lives in one menu.
            Menu {
                if let planID = model.currentServiceID, !runOnly {
                    Button("Message & Series…", systemImage: "text.book.closed") { messagePlanID = planID }
                }
                if !runOnly { themesMenu }
                if !runOnly, layout != nil {
                    Button("Simple Mode…", systemImage: "lock") { requestSimpleMode() }
                }
                if controls != nil {
                    Button("Timers & Macros…", systemImage: "timer") { controlsShown = true }
                }
                if !runOnly { Button("Lower Thirds…", systemImage: "rectangle.bottomthird.inset.filled") { ScreensByTypeRouter.shared.shown = true } }
                Button("Screen Setup…", systemImage: "display.2") { openWindow(id: "outputs") }
                Button("Edit Stage Display…", systemImage: "rectangle.inset.filled.and.person.filled") { editStageDisplay() }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Message & Series, Themes, Simple Mode, Timers & Macros, Screen Setup")
            if screensMenuShown {
                Button { togglePanel(.screens) } label: {
                    Label(screensPanel.isPinned ? "Fold Screens" : "Pin Screens", systemImage: "sidebar.right")
                }
                .help(screensPanel.isPinned ? "Fold the screens to the strip (⌃⌘R)" : "Keep the screens open beside the slides (⌃⌘R)")
            }
        }
    }

    // MARK: Countdown

    /// Every upcoming service (not a template, not a past plan) opens with
    /// a countdown. An item the plan already has that is one (Shepherd's
    /// "COUNTDOWN", or one linked to a countdown video or presentation) is
    /// marked as it; otherwise the plan gets an empty Countdown item first,
    /// to be given this week's video, unless its countdown was taken out.
    private func ensureCountdowns() {
        guard !runOnly else { return }
        for plan in plans.upcoming {
            guard let change = ServiceCountdown.change(for: plan, isCountdownLink: isCountdownLink) else { continue }
            model.updateService(plan.id) { service in
                ServiceCountdown.apply(change, to: &service)
            }
        }
    }

    /// Linked to a video in Media › Countdowns, or to a presentation named
    /// Countdown.
    private func isCountdownLink(_ item: ServiceItem) -> Bool {
        guard !item.refId.isEmpty else { return false }
        switch item.itemKind {
        case .media: return ServiceCountdown.isCountdownFolder(model.media(item.refId)?.folder)
        case .presentation: return model.entry(item.refId).map { ServiceCountdown.looksLikeCountdown($0.name) } == true
        default: return false
        }
    }

    // MARK: Bible

    /// Click to add a passage; the arrow holds listening and the Bible theme,
    /// which can change while a passage is up.
    private var bibleMenu: some View {
        let assist = LiveAssist.shared
        // Unset means the built-in Scripture theme, which is what new passages use.
        let current = model.slideBuilding.scriptureThemeId ?? BasicTemplates.scriptureThemeID
        return Menu {
            Button("Add Scripture…") { scriptureShown = true }
            Divider()
            if assist.listening {
                Button("Stop Listening", systemImage: "mic.slash") { assist.stop() }
            } else {
                Button("Listen for Scripture", systemImage: "mic") {
                    assist.showsAutomatically = true
                    Task { await assist.startSermon() }
                }
            }
            Divider()
            Section("Bible Theme") {
                ForEach(bibleThemes, id: \.id) { theme in
                    Button {
                        setBibleTheme(theme.id)
                    } label: {
                        if theme.id == current { Label(theme.name, systemImage: "checkmark") } else { Text(theme.name) }
                    }
                }
            }
        } label: {
            Label("Bible", systemImage: assist.listening ? "waveform" : "book")
                .foregroundStyle(assist.listening ? HopeStyle.live : Color.primary)
        } primaryAction: {
            scriptureShown = true
        }
        .help(assist.listening ? "Listening for scripture. Click to add a passage." : "Add scripture (⌘⇧B)")
    }

    /// Themes to show scripture in: full-screen designs, not their lower thirds.
    private var bibleThemes: [LibraryIndex.Entry] {
        model.entries(of: .theme)
            .filter { !$0.name.localizedCaseInsensitiveContains("lower third") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The default for new passages, and the passage on screen now takes it too.
    private func setBibleTheme(_ themeID: String) {
        model.updateSlideBuilding { $0.scriptureThemeId = themeID }
        if let live = controls?.state.liveSlide?.presentation,
           PresentationTypes.category(of: live) == PresentationTypes.bible {
            model.applyTheme(to: live.id, themeID: themeID)
        }
    }

    // MARK: Themes

    /// Every theme, one click from the editor: this plan's series first,
    /// since that's the one most often adjusted, then the rest by name.
    private var themesMenu: some View {
        let seriesID = model.currentServiceID.flatMap { model.resident.services.value($0)?.sermonThemeId }
            ?? model.slideBuilding.sermonThemeId
        let themes = model.entries(of: .theme)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let series = themes.first { $0.id == seriesID }
        let others = themes.filter { $0.id != series?.id }
        return Menu("Themes", systemImage: "paintpalette") {
            if let series {
                Section("This Plan’s Series") {
                    Button(series.name) { editTheme(series.id) }
                }
                Section("Other Themes") {
                    ForEach(others, id: \.id) { theme in Button(theme.name) { editTheme(theme.id) } }
                }
            } else {
                ForEach(others, id: \.id) { theme in Button(theme.name) { editTheme(theme.id) } }
            }
            Divider()
            Button("New Theme from Image…") { themeFromImage = true }
            Button("Show Themes in Library") {
                topPane = .library
                model.switchLibrarySection(.themes)
            }
        }
    }

    /// The workspace, with More › Themes › New Theme from Image… and the
    /// requests from sheets that made or picked a theme to open it in the
    /// editor. Kept out of `body`, whose chain of modifiers is already as
    /// long as the compiler will check.
    private var themeRouted: some View {
        workspace
            .sheet(isPresented: $themeFromImage) {
                ThemeFromImageSheet(model: model) { id in editTheme(id) }
            }
            .onChange(of: ThemeEditorRouter.shared.requests) { _, _ in
                if let id = ThemeEditorRouter.shared.themeID { editTheme(id) }
            }
    }

    /// Opens the theme in the editor, in place of whatever plan item was open.
    private func editTheme(_ id: String) {
        itemID = nil
        model.openInEditor(entryID: id)
        modeRaw = AppMode.edit.rawValue
    }

    // MARK: Stage display

    private func editStageDisplay() {
        StageEditorButton.open(model: model) { id in
            itemID = nil
            model.openInEditor(entryID: id)
            modeRaw = AppMode.edit.rawValue
        }
    }

    private func addToPlan(_ presentationID: String) {
        guard let planID = model.currentServiceID else { return }
        let name = model.indexEntry(presentationID)?.name ?? "Scripture"
        append(ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: name, refId: presentationID), to: planID)
    }

    // MARK: Adding to the plan

    enum NewKind { case song, deck, slideshow, message }

    private func addHeader(_ planID: String) {
        let item = ServiceItem(id: UUID().uuidString, itemKind: .header, name: "New Section", refId: "")
        append(item, to: planID)
    }

    /// A new presentation with no slides yet, added at the end of the plan
    /// (or after the selected item) and opened for editing.
    private func addPresentation(_ planID: String, kind: NewKind) {
        let name: String
        var presentation = Presentation(
            id: UUID().uuidString, name: "", presentationKind: .deck, themeId: "", slides: [])
        switch kind {
        case .song:
            name = "New Song"
            presentation.presentationKind = .song
            presentation.category = PresentationTypes.worship
            presentation.themeId = model.slideBuilding.lyricsImportThemeId ?? BasicTemplates.worshipThemeID
        case .deck:
            name = "New Presentation"
        case .slideshow:
            name = "New Slideshow"
            presentation.autoAdvance = AutoAdvance(delaySeconds: 8, loopToStart: true)
        case .message:
            name = "Message"
            presentation.category = PresentationTypes.sermon
            presentation.themeId = model.resident.services.value(planID)?.sermonThemeId
                ?? model.slideBuilding.sermonThemeId ?? BasicTemplates.pointsThemeID
            let id = presentation.id
            model.updateService(planID) { $0.messagePresentationId = id }
        }
        presentation.name = name
        model.createInDrive(presentation)
        append(ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: name, refId: presentation.id), to: planID)
        modeRaw = AppMode.edit.rawValue
    }

    private func addMedia(_ urls: [URL]) async {
        guard let planID = model.currentServiceID else { return }
        for id in await model.importFiles(urls) {
            let name = model.media(id)?.name ?? "Video"
            append(ServiceItem(id: UUID().uuidString, itemKind: .media, name: name, refId: id), to: planID)
        }
    }

    private func append(_ item: ServiceItem, to planID: String) {
        let after = itemID
        model.updateService(planID) { plan in
            let index = after.flatMap { id in plan.items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? plan.items.count
            plan.items.insert(item, at: index)
        }
        itemID = item.id
    }
}

/// A plain id for sheet(item:).
struct IdentifiedID: Identifiable, Hashable {
    let id: String
}

/// Asks for the microphone only when the person clicks, so the prompt never
/// lands on a launch that's still setting up its audio devices.
private struct MicrophoneAccessBanner: View {
    var body: some View {
        Button { AudioInputInventory.shared.requestMicrophoneAccess() } label: {
            Label("Allow Microphone Access", systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(nil)
        .help("Live audio inputs are waiting for microphone access")
    }
}

/// Slide size at the bottom of the slides, like ProPresenter's: drag right
/// for bigger slides (fewer to a row), left for more at once. Auto, the
/// default, fits the slides to the page's width; dragging picks a size, and
/// clicking Auto goes back to fitting.
private struct SlideSizeControl: View {
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback
    /// With its chip's padding; the control bar is centred against it.
    static let width: CGFloat = 214

    private var automatic: Bool { SlidesAcross.isAutomatic(slidesAcross) }

    var body: some View {
        let range = SlidesAcross.range
        // While fitting, the thumb sits where an unmeasured page starts
        // rather than at an end, which would read as a choice.
        let shown = automatic ? SlidesAcross.unmeasuredCount : SlidesAcross.clamped(slidesAcross)
        HStack(spacing: 6) {
            Button {
                slidesAcross = SlidesAcross.automatic
            } label: {
                Text("Auto")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(automatic ? Color.white : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(automatic ? HopeStyle.blue : Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(automatic ? "Fitting the slides to the window" : "Go back to fitting the slides to the window")
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 10))
            Slider(
                value: Binding(
                    // Reversed: the right end is the fewest across, the biggest slides.
                    get: { Double(range.upperBound + range.lowerBound - shown) },
                    set: { raw in
                        let next = SlidesAcross.clamped(range.upperBound + range.lowerBound - Int(raw.rounded()))
                        if next != slidesAcross { slidesAcross = next }
                    }),
                in: Double(range.lowerBound) ... Double(range.upperBound), step: 1)
                .controlSize(.small)
                .frame(width: 110)
                .opacity(automatic ? 0.6 : 1)
            Image(systemName: "square.fill").font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .help("Slide size")
    }
}

private extension View {
    /// A small floating control over the slides.
    func glassChip() -> some View {
        padding(.horizontal, 12)
            .frame(height: 34)
            .glassEffect(.regular, in: Capsule())
    }
}
