import PresenterCore
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// The main window: plans first. The sidebar lists plans (upcoming by
/// date) with the library tucked below; the middle column is the chosen
/// plan's order of items; the slides fill the center; every screen previews
/// in the column on the right. Native split view and toolbar, so macOS draws
/// the glass and nothing custom redraws behind it.
struct PlanShell: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    @AppStorage("appMode") private var modeRaw = AppMode.present.rawValue
    @AppStorage("shell.screensShown") private var screensShown = true
    @AppStorage("shell.libraryShown") private var libraryShown = true
    @State private var itemID: String?
    @State private var creatingPlan = false
    @State private var controlsShown = false
    @State private var addingVideo = false
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    private var mode: AppMode { AppMode(rawValue: modeRaw) ?? .present }
    private var runOnly: Bool { layout?.runOnly ?? false }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } content: {
            planColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            center
        }
        .inspector(isPresented: $screensShown) {
            Group {
                if let render { MonitorsPanel(render: render) } else { Color.clear }
            }
            .inspectorColumnWidth(min: 240, ideal: 320, max: 520)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $creatingPlan) {
            NewServiceSheet(model: model) { id in model.currentServiceID = id }
        }
        .fileImporter(isPresented: $addingVideo, allowedContentTypes: [.movie, .video, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await addMedia(urls) }
        }
        .onChange(of: model.currentServiceID) { _, _ in itemID = nil }
        .task { await model.resident.ready([.service]) }
    }

    // MARK: Sidebar — plans, then the library

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.currentServiceID },
                set: { if let id = $0 { model.currentServiceID = id } }
            )) {
                Section("Upcoming") {
                    ForEach(plans.upcoming, id: \.id) { planRow($0) }
                    if plans.upcoming.isEmpty {
                        Text("No upcoming plans").foregroundStyle(.secondary)
                    }
                }
                if !plans.past.isEmpty {
                    Section("Past") {
                        ForEach(plans.past, id: \.id) { planRow($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)

            if !runOnly {
                Divider()
                DisclosureGroup(isExpanded: $libraryShown) {
                    LibrarySidebar(model: model, render: render, layout: layout, controls: controls)
                        .frame(height: 300)
                } label: {
                    Label("Library", systemImage: "books.vertical").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .top) {
            if !runOnly {
                HStack {
                    Text("Plans").font(.headline)
                    Spacer()
                    Button { creatingPlan = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New plan")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    private func planRow(_ plan: Service) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(plan.name).lineLimit(1)
            if let date = Self.dateLabel(plan.serviceDate) {
                Text(date).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(plan.id)
    }

    /// Upcoming plans soonest first, then past plans newest first.
    private var plans: (upcoming: [Service], past: [Service]) {
        let today = Self.dayFormatter.string(from: .now)
        let all = Array(model.resident.services.values)
        let upcoming = all.filter { ($0.serviceDate ?? "") >= today || $0.serviceDate == nil }
            .sorted { ($0.serviceDate ?? "9999", $0.name) < ($1.serviceDate ?? "9999", $1.name) }
        let past = all.filter { ($0.serviceDate ?? "9999") < today }
            .sorted { ($0.serviceDate ?? "", $0.name) > ($1.serviceDate ?? "", $1.name) }
        return (upcoming, past)
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
    private var planColumn: some View {
        if let planID = model.currentServiceID {
            RunOrderList(
                model: model, controls: controls, serviceID: planID, render: render,
                selectedItemID: $itemID)
                .navigationTitle(model.resident.services.value(planID)?.name ?? "Plan")
                .toolbar {
                    if !runOnly {
                        ToolbarItem { addMenu(planID: planID) }
                    }
                }
        } else {
            ContentUnavailableView {
                Label("No Plan", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Choose a plan, or make a new one.")
            } actions: {
                if !runOnly { Button("New Plan") { creatingPlan = true } }
            }
        }
    }

    private func addMenu(planID: String) -> some View {
        Menu {
            Button("Header", systemImage: "textformat") { addHeader(planID) }
            Divider()
            Button("Song", systemImage: "music.note") { addPresentation(planID, kind: .song) }
            Button("Presentation", systemImage: "rectangle.on.rectangle") { addPresentation(planID, kind: .deck) }
            Button("Slideshow", systemImage: "play.rectangle.on.rectangle") { addPresentation(planID, kind: .slideshow) }
            Button("Video or Image…", systemImage: "film") { addingVideo = true }
            Button("Message", systemImage: "text.book.closed") { addPresentation(planID, kind: .message) }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add to this plan")
    }

    // MARK: Center

    @ViewBuilder
    private var center: some View {
        switch mode {
        case .present:
            if let planID = model.currentServiceID {
                ServiceItemDetailView(
                    model: model, render: render, controls: controls, serviceID: planID, itemID: itemID)
            } else {
                ContentUnavailableView("Nothing to Show", systemImage: "rectangle.on.rectangle",
                                       description: Text("Pick a plan on the left."))
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
            ContentUnavailableView("Nothing to Edit", systemImage: "pencil",
                                   description: Text("Pick an item in the plan, or something in the library."))
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
            if let controls {
                Button { controlsShown.toggle() } label: {
                    Label("Controls", systemImage: "slider.horizontal.3")
                }
                .help("Timers, macros and the sermon microphone")
                .popover(isPresented: $controlsShown, arrowEdge: .bottom) {
                    ShowControlsPanel(model: model, controls: controls)
                        .frame(width: 360, height: 440)
                }
            }
            Button { openWindow(id: "outputs") } label: {
                Label("Screen Setup", systemImage: "display.2")
            }
            .help("Which screen is which: audience, livestream, stage")
            Button { screensShown.toggle() } label: {
                Label("Screens", systemImage: "sidebar.right")
            }
            .help("Show or hide the screen previews")
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
            presentation.themeId = model.slideBuilding.sermonThemeId ?? BasicTemplates.pointsThemeID
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
