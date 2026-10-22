import PresenterCore
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// The main window, laid out like ProPresenter: on the left, the plans (or
/// the library) above the chosen plan's items; the slides fill the middle;
/// every screen previews down the right, with Clear All under them. Native
/// split view and toolbar, so macOS draws the glass and nothing custom
/// redraws behind it.
struct PlanShell: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    @AppStorage("appMode") private var modeRaw = AppMode.present.rawValue
    @AppStorage("shell.screensShown") private var screensShown = true
    @AppStorage("shell.topPane") private var topPane = TopPane.plans
    @State private var itemID: String?
    /// The left column was folded away for Edit (so it comes back after).
    @State private var foldedForEdit = false
    @State private var creatingPlan = false
    @State private var controlsShown = false
    @State private var addingVideo = false
    /// Songs open in the song editor; this switches to the slide editor.
    @State private var songSlideEditor = false
    @State private var messagePlanID: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The screens column's width: room for a 16:9 preview a third of the
    /// window wide, and a fixed number so nothing in it can resize the split.
    static let screensWidth: CGFloat = 360

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
        // Every column gets a fixed minimum and is free to shrink inside it:
        // content that reports its own changing minimum size makes the split
        // view re-run constraints forever, and AppKit then ends the app.
        NavigationSplitView {
            // The library inside needs 272 to lay out; narrower clips it.
            sidebar
                .frame(minWidth: 272, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .navigationSplitViewColumnWidth(min: 272, ideal: 300, max: 420)
        } detail: {
            // The screens sit beside the slides at a fixed width rather than
            // in a split-view inspector: next to a two-column split, the
            // inspector's size negotiation never settles and AppKit ends the app.
            HStack(spacing: 0) {
                center
                    .frame(minWidth: 320, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .animation(HopeMotion.ui(reduced: reduceMotion), value: modeRaw)
                    .animation(HopeMotion.ui(reduced: reduceMotion), value: itemID)
                // Edit gives the editor the room; Present and Schedule show the screens.
                if screensShown && mode != .edit, let render {
                    Divider()
                    MonitorsPanel(
                        render: render, liveKey: controls?.liveSlideID,
                        onClearAll: controls.map { controls in { controls.clearAll() } })
                        .frame(width: Self.screensWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Edit folds the left column away so the slide canvas gets the
            // room; Present and Schedule bring it back.
            // Uses the split view's own toggle: driving columnVisibility
            // instead made the window open 300 points wider every launch.
            .onChange(of: modeRaw) {
                // Only with something to edit; otherwise the left column is
                // where you'd pick it.
                if mode == .edit, !foldedForEdit, selectedRefID != nil {
                    foldedForEdit = true
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                } else if mode != .edit, foldedForEdit {
                    foldedForEdit = false
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
            }
            .navigationTitle(model.currentServiceID.flatMap { model.resident.services.value($0)?.name } ?? "Screens")
        }
        .toolbar { toolbar }
        .tint(HopeStyle.blue)
        .preferredColorScheme(.dark)
        // The menu bar's commands (File › New, Import, the Present menu, …)
        // find the library and the show through these.
        .focusedSceneValue(\.libraryModel, model)
        .focusedSceneValue(\.serviceControls, controls)
        .focusedSceneValue(\.presentWorkspaceImport, workspaceImportAction)
        .focusedSceneValue(\.presentLibrarySearch, findInLibraryAction)
        .focusedSceneValue(\.presentNewSlide, mode == .present ? Self.presentNewSlideAction : nil)
        .environment(\.runOnly, runOnly)
        .sheet(item: Binding(get: { messagePlanID.map(IdentifiedID.init) }, set: { messagePlanID = $0?.id })) { plan in
            PlanMessageSheet(model: model, planID: plan.id)
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
        .onChange(of: model.currentServiceID) { _, _ in itemID = nil }
        .onChange(of: itemID) { _, _ in songSlideEditor = false }
        .task {
            await model.resident.ready([.service])
            // A plan remembered from a library that's since been wiped.
            if let id = model.currentServiceID, model.resident.services.value(id) == nil {
                model.currentServiceID = nil
            }
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
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    Button("Save as Template") { saveTemplate(from: plan) }
                }
            }
        }
    }

    /// A template copy of a plan: the same order, headers and colors, with
    /// links to the same presentations; a message stays a placeholder.
    private func saveTemplate(from plan: Service) {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                RunOrderList(
                    model: model, controls: controls, serviceID: planID, render: render,
                    selectedItemID: $itemID, planAdds: PlanAddActions(
                        song: { addPresentation(planID, kind: .song) },
                        deck: { addPresentation(planID, kind: .deck) },
                        slideshow: { addPresentation(planID, kind: .slideshow) },
                        media: { addingVideo = true },
                        message: { addPresentation(planID, kind: .message) }))
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
                ServiceItemDetailView(
                    model: model, render: render, controls: controls, serviceID: planID, itemID: itemID)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            Divider()
                            HStack {
                                Spacer()
                                SlideSizeControl()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .background(.bar)
                    }
            } else {
                HopeEmptyState(title: "Nothing to Show", symbol: "sparkles.rectangle.stack",
                               message: "Pick a plan on the left.")
            }
        case .edit:
            editor
        case .scheduler:
            SchedulerView(model: model, controls: controls)
        }
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
            // Everything not used every minute of a service lives in one menu.
            Menu {
                if let planID = model.currentServiceID, !runOnly {
                    Button("Message & Series…", systemImage: "text.book.closed") { messagePlanID = planID }
                }
                if controls != nil {
                    Button("Timers & Macros…", systemImage: "timer") { controlsShown = true }
                }
                Button("Screen Setup…", systemImage: "display.2") { openWindow(id: "outputs") }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Message & Series, Timers & Macros, Screen Setup")
            Button { withAnimation(HopeMotion.ui(reduced: reduceMotion)) { screensShown.toggle() } } label: {
                Label("Screens", systemImage: "sidebar.right")
            }
            .help("Show or hide the screens")
        }
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
/// for bigger slides (fewer to a row), left for more at once.
private struct SlideSizeControl: View {
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback

    var body: some View {
        let range = SlidesAcross.range
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 10))
            Slider(
                value: Binding(
                    // Reversed: the right end is the fewest across, the biggest slides.
                    get: { Double(range.upperBound + range.lowerBound - SlidesAcross.clamped(slidesAcross)) },
                    set: { raw in
                        let next = SlidesAcross.clamped(range.upperBound + range.lowerBound - Int(raw.rounded()))
                        if next != slidesAcross { slidesAcross = next }
                    }),
                in: Double(range.lowerBound) ... Double(range.upperBound), step: 1)
                .controlSize(.small)
                .frame(width: 120)
            Image(systemName: "square.fill").font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .help("Slide size")
    }
}
