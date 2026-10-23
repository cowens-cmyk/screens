import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

struct RunOrderList: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var controls: ServiceControls?
    let serviceID: String

    var render: RenderContext?
    @Binding var selectedItemID: String?

    var onReselect: () -> Void = {}
    /// The plan window's kinds of new item (song, message, …); without it
    /// the add menu offers the older generic choices.
    var planAdds: PlanAddActions? = nil

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    @State private var addingHeader = false
    @State private var headerText = ""
    @State private var collapsedHeaders: Set<String> = []

    @State private var showHidden = false

    private var collapseKey: String { "runOrder.collapsed.\(serviceID)" }

    private func loadCollapsed() {
        collapsedHeaders = Set(
            UserDefaults.standard.stringArray(forKey: collapseKey) ?? []
        )
    }

    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsedHeaders), forKey: collapseKey)
    }

    @State private var renamingItem: ServiceItem?
    @State private var itemRenameText = ""

    @State private var applyThemeTarget: ApplyThemeTarget?

    @State private var selection: Set<String> = []

    @State private var rowFrames: [String: CGRect] = [:]

    @State private var marqueeRect: CGRect?

    @State private var marqueeBase: Set<String> = []

    @State private var addingFromLibrary = false

    @State private var dropTargetItemID: String?

    @State private var mediaMenuState = MediaCueMenuState()

    private var renamingItemActive: Binding<Bool> {
        Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
    }

    var body: some View {
        if let service = try? model.service(serviceID) {
            let visible = visibleItems(service)
            let order = visible.map(\.id)
            let changed = model.versionChangedItemIDs(serviceID)
            VStack(spacing: 0) {
                runOrderList(service: service, visible: visible, order: order, changed: changed)
                    .animation(HopeMotion.ui(reduced: reduceMotion), value: order)
                if !runOnly {
                    Divider()
                    addBar
                }
            }
            // A SongSelect or ChordPro file dropped anywhere on the plan
            // (between rows places it; see onInsert).
            .dropDestination(for: URL.self) { urls, _ in
                let lyrics = urls.filter { LyricsFetcher.lyricExtensions.contains($0.pathExtension.lowercased()) }
                guard !runOnly, !lyrics.isEmpty else { return false }
                for url in lyrics {
                    LyricsFetcher.shared.importDropped(url, planID: serviceID, beforeItemID: nil, model: model)
                }
                return true
            }
            .onAppear {
                loadCollapsed()
                if let id = selectedItemID { selection = [id] }
            }
            .onChange(of: selection) { _, selection in selectionChanged(selection, visible: visible) }
            .onChange(of: selectedItemID) { _, id in surfaceItemChanged(id) }
            .alert("Add Header", isPresented: $addingHeader) {
                TextField("Header", text: $headerText)
                Button("Add") {
                    model.addServiceHeader(serviceID, name: headerText)
                    headerText = ""
                }
                Button("Cancel", role: .cancel) { headerText = "" }
            }
            .sheet(item: $applyThemeTarget) { target in
                ApplyThemeSheet(
                    appModel: model, render: render, deckThemeId: model.themeID(of: target.presentationID),
                    scope: "Applies to every slide in \u{201C}\(model.entry(target.presentationID)?.name ?? "this presentation")\u{201D}"
                        + (model.presentationHasSlideThemes(target.presentationID)
                            ? ", slides with a theme of their own too." : ".")
                ) { themeId, design in
                    model.applyTheme(to: target.presentationID, themeID: themeId, design: design)
                }
            }
            .alert("Rename Item", isPresented: renamingItemActive) {
                TextField("Name", text: $itemRenameText)
                Button("Rename") {
                    if let target = renamingItem,
                       let entry = model.indexEntry(target.refId) {
                        model.rename(entry, to: itemRenameText)
                    }
                    renamingItem = nil
                }
                Button("Cancel", role: .cancel) { renamingItem = nil }
            } message: {
                Text("This renames the item in the library too — everywhere it's used.")
            }
            .sheet(isPresented: $addingFromLibrary) {
                LibrarySearchSheet(model: model, serviceID: serviceID)
            }
            .mediaCueSheets(model: model, state: mediaMenuState)
        } else {
            ContentUnavailableView("Service not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    private func runOrderList(
        service: Service, visible: [ServiceItem], order: [String], changed: Set<String>
    ) -> some View {
        List(selection: $selection) {
            ForEach(visible, id: \.id) { item in
                if item.itemKind == .header {

                    headerRow(item, order: order)
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(headerColor(item))
                                .padding(.vertical, 1)
                                .padding(.horizontal, 6))
                        .reportingGlobalFrame(id: item.id, into: $rowFrames)

                        .draggablePayload(runOnly ? nil : "svc::" + item.id)
                } else {
                    itemRow(item, order: order, changed: changed.contains(item.id))
                        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(liveRowBackground(item))
                        .reportingGlobalFrame(id: item.id, into: $rowFrames)
                        .draggablePayload(runOnly ? nil : "svc::" + item.id)
                }
            }
            .onInsert(of: [.plainText, .text, .fileURL]) { index, providers in
                guard !runOnly else { return }
                let anchorID = visible.indices.contains(index) ? visible[index].id : nil
                for provider in providers {
                    // A SongSelect or ChordPro file from Finder.
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, LyricsFetcher.lyricExtensions.contains(url.pathExtension.lowercased())
                            else { return }
                            Task { @MainActor in
                                LyricsFetcher.shared.importDropped(
                                    url, planID: serviceID, beforeItemID: anchorID, model: model)
                            }
                        }
                        continue
                    }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let payload = object as? String else { return }
                        Task { @MainActor in
                            insertPayload(payload, beforeItemID: anchorID)
                        }
                    }
                }
            }
            let hidden = ServiceRunOrder.hidden(service.items)
            if !hidden.isEmpty {
                hiddenGroupRow(count: hidden.count)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if showHidden {
                    ForEach(hidden, id: \.id) { item in
                        hiddenRow(item)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // ProPresenter-dense rows, so a whole service fits without scrolling.
        .environment(\.defaultMinListRowHeight, 22)

        .onDeleteCommand {
            guard !runOnly, !selection.isEmpty else { return }
            requestRemoval(order.filter(selection.contains))
        }
        .listMarquee(
            active: !runOnly, rowFrames: Array(rowFrames.values),
            began: marqueeBegan, changed: marqueeChanged, ended: marqueeEnded,
            pressedRow: { rowPressed($0, $1, visible: visible) })
        .inputRegion("run order")
        .overlay { ListMarqueeBand(rect: marqueeRect) }
    }

    private func marqueeBegan(_ modifiers: NSEvent.ModifierFlags) {
        InputTrailRecorder.shared.record("marquee in run order")
        marqueeBase = modifiers.contains(.shift) ? selection : []
        if !modifiers.contains(.shift), !modifiers.contains(.command) {
            selection = []
        }
    }

    private func rowPressed(
        _ point: CGPoint, _ modifiers: NSEvent.ModifierFlags, visible: [ServiceItem]
    ) -> (() -> Void)? {
        let id = rowFrames.first(where: { $0.value.contains(point) })?.key
        if let id, RunOrderSelection.isReselect(
            pressed: id, current: selectedItemID,
            command: modifiers.contains(.command), shift: modifiers.contains(.shift),
            control: modifiers.contains(.control)) {
            let name = visible.first { $0.id == id }?.name ?? "-"
            return {
                DiagnosticsStore.shared.note(
                    "runOrder.click", detail: "\(id) \"\(name)\" already selected: jump back to it")
                onReselect()
            }
        } else {
            return nil
        }
    }

    private func marqueeChanged(_ band: CGRect) {
        marqueeRect = band
        selection = RunOrderSelection.swept(frames: rowFrames, band: band, keeping: marqueeBase)
    }

    private func marqueeEnded() {
        marqueeRect = nil
        marqueeBase = []
    }

    private func selectionChanged(_ selection: Set<String>, visible: [ServiceItem]) {
        let surface = RunOrderSelection.surfaceItem(
            selection: selection, current: selectedItemID, rows: visible)
        if surface != selectedItemID {

            let name = { (id: String?) in id.flatMap { id in visible.first { $0.id == id }?.name } ?? "-" }
            DiagnosticsStore.shared.note(
                "runOrder.surface",
                detail: "\(selectedItemID ?? "-") → \(surface ?? "-") (\(selection.count) selected)"
                    + " \"\(name(selectedItemID))\" → \"\(name(surface))\"; \(InputTrailRecorder.shared.cause())")
            selectedItemID = surface
        }
    }

    private func surfaceItemChanged(_ id: String?) {
        if let id {
            if !selection.contains(id) { selection = [id] }
        } else if !selection.isEmpty {
            selection = []
        }
    }

    private func visibleItems(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.sidebarRows(service.items, collapsedHeaders: collapsedHeaders, timeHexId: nil, order: nil)
    }

    private func insertPayload(_ payload: String, beforeItemID: String?) {
        let added: ServiceItem? = if !payload.hasPrefix("svc::"), let ref = model.indexEntry(payload),
            let kind: ServiceItemKind = ref.kind == .presentation ? .presentation
                : ref.kind == .media ? .media
                : ref.kind == .audio ? .audio
                : ref.kind == .playlist ? .playlist : nil {
            ServiceItem(id: UUID().uuidString, itemKind: kind, name: ref.name, refId: payload)
        } else {
            nil
        }
        model.updateService(serviceID) { service in
            let insertIndex = beforeItemID.flatMap { id in
                service.items.firstIndex { $0.id == id }
            } ?? service.items.count
            if payload.hasPrefix("svc::") {
                let movingID = String(payload.dropFirst("svc::".count))
                guard let from = service.items.firstIndex(where: { $0.id == movingID })
                else { return }
                let item = service.items.remove(at: from)
                let target = from < insertIndex ? insertIndex - 1 : insertIndex
                service.items.insert(item, at: min(max(target, 0), service.items.count))
            } else if let added {
                service.items.insert(added, at: min(insertIndex, service.items.count))
            }
        }
    }

    private func headerRow(_ item: ServiceItem, order: [String]) -> some View {
        let collapsed = collapsedHeaders.contains(item.id)
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if collapsed {
                        collapsedHeaders.remove(item.id)
                    } else {
                        collapsedHeaders.insert(item.id)
                    }
                }
                persistCollapsed()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(headerText(item).opacity(0.8))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")
            // A solid band in the header's color, like ProPresenter's
            // playlist headers.
            Text(item.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(headerText(item))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            if !runOnly {
                let batch = ListMultiSelect.batch(clicked: item.id, selection: selection, order: order)
                if batch.count > 1 {
                    bulkMenu(batch)
                } else {
                    headerColorMenu(item)
                    Divider()

                    Button("Hide") { hide([item.id]) }
                    removeButton(item)
                }
            }
        }

        .id("runOrderHeaderMenu|\(item.id)|\(inMultiSelection(item.id))")
    }

    /// A header's band: its own color, else a muted Hope navy.
    private func headerColor(_ item: ServiceItem) -> Color {
        item.colorHex.flatMap(ColorHex.color).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue)
        } ?? HopeStyle.navy.opacity(0.85)
    }

    private func headerText(_ item: ServiceItem) -> Color {
        GroupColor.text(onHex: item.colorHex)
    }

    private func inMultiSelection(_ id: String) -> Bool {
        selection.count > 1 && selection.contains(id)
    }

    @ViewBuilder
    private func bulkMenu(_ ids: [String]) -> some View {
        Text("\(ids.count) Items")
        Divider()
        Button("Hide") { hide(ids) }
        Button("Remove from Service", role: .destructive) { requestRemoval(ids) }
    }

    @ViewBuilder
    private func itemRow(_ item: ServiceItem, order: [String], changed: Bool) -> some View {
        HStack(spacing: 8) {
            // An item's color, like a header's, shows as a stripe at its edge.
            if let tint = item.colorHex.flatMap(ColorHex.color) {
                Capsule()
                    .fill(Color(red: tint.red, green: tint.green, blue: tint.blue))
                    .frame(width: 3, height: 16)
            }
            ItemKindBadge(kind: HopeStyle.kind(
                of: item, presentation: item.itemKind == .presentation ? model.presentation(item.refId) : nil),
                live: isItemLive(item))

            Text(displayName(item))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.itemKind == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .layoutPriority(0)
            Spacer(minLength: 4)

            // A planned song with no presentation in the library: flag it so
            // it gets imported or linked before Sunday.
            if item.itemKind == .info, item.refId.isEmpty, item.mxuSongTitle != nil {
                getLyricsButton(item)
            }

            if changed {
                Text("Changed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Changed in this version. Right-click and choose Use Main's to undo it.")
            }

            if item.itemKind == .presentation,
               let override = arrangementName(item) {
                Text(override)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .padding(-4)
                .opacity(dropTargetItemID == item.id ? 1 : 0)
        )
        .dropDestination(for: String.self) { payloads, _ in

            if !runOnly, item.itemKind == .presentation,
               let dragged = payloads.first.flatMap(SlideBulkEdit.draggedSlide(in:)) {
                return model.copySlide(
                    dragged.slideID, from: dragged.presentationID,
                    to: item.refId, beforeSlideID: nil)
            } else {
                return false
            }
        } isTargeted: { over in

            let slideDrag = NSPasteboard(name: .drag).string(forType: .string)
                .flatMap(SlideBulkEdit.draggedSlide(in:))
            let accepts = item.itemKind == .presentation && slideDrag.map { $0.presentationID != item.refId } == true
            if over, accepts {
                dropTargetItemID = item.id
            } else if !over, dropTargetItemID == item.id {
                dropTargetItemID = nil
            }
        }
        .contextMenu {
            let batch = ListMultiSelect.batch(clicked: item.id, selection: selection, order: order)
            if !runOnly, batch.count > 1 {
                bulkMenu(batch)
            } else if !runOnly {

                if let entry = model.entry(item.refId), entry.kind.opensInEditor {
                    Button("Edit…") {
                        model.openInEditor(entryID: entry.id)
                        appModeRaw = AppMode.edit.rawValue
                    }
                    Divider()
                }
                headerColorMenu(item)
                Divider()

                if item.itemKind == .presentation {
                    SlideshowMenu(model: model, presentationID: item.refId)
                }
                if item.itemKind == .media {
                    VideoEndMenu(model: model, mediaID: item.refId)
                    MediaCueMenuItems(
                        model: model, actionRouter: controls?.actionRouter,
                        mediaID: item.refId, state: mediaMenuState,
                        fallbackName: item.name
                    )
                } else if item.itemKind != .info {

                    Button("Rename…") {
                        renamingItem = item
                        itemRenameText = displayName(item)
                    }
                    if item.itemKind == .presentation {
                        arrangementMenu(item)

                        Button("Apply Theme…") {
                            applyThemeTarget = ApplyThemeTarget(presentationID: item.refId, slideIDs: nil)
                        }
                    }
                }
                Divider()
                Button("Hide") { hide([item.id]) }
                if changed {
                    Button("Use Main's") { model.useMainForServiceItem(serviceID, itemID: item.id) }
                }
                removeButton(item)
            }
        }

        .id("runOrderRowMenu|\(item.id)|\(item.itemKind.rawValue)|\(item.itemKind == .media && model.media(item.refId) == nil)|\(inMultiSelection(item.id))")
    }

    private func displayName(_ item: ServiceItem) -> String {
        model.entry(item.refId)?.name ?? item.name
    }

    /// A planned song with no slides: one click fetches them, from Shepherd
    /// or SongSelect (see LyricsFetcher).
    @ViewBuilder
    private func getLyricsButton(_ item: ServiceItem) -> some View {
        let fetcher = LyricsFetcher.shared
        if fetcher.waitingItemID == item.id {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Button("Cancel") { fetcher.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .help(fetcher.status ?? "")
        } else {
            Button {
                Task { await fetcher.getLyrics(for: item, planID: serviceID, model: model) }
            } label: {
                Label("Get Lyrics", systemImage: "text.badge.plus")
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(runOnly || fetcher.waitingItemID != nil)
            .help("No slides for this song yet. Looks in Shepherd; if it isn't there, opens SongSelect and imports the lyrics file you download.")
        }
    }

    @ViewBuilder
    private func liveRowBackground(_ item: ServiceItem) -> some View {
        if isItemLive(item) {
            RoundedRectangle.standard(CornerStandard.element)
                .fill(Color.primary.opacity(0.08))
                .padding(.vertical, 1)
        }
    }

    private func isItemLive(_ item: ServiceItem) -> Bool {
        guard let controls else { return false }
        switch item.itemKind {
        case .presentation: return controls.liveContextID == item.id
        case .media: return controls.isMediaLive(item.refId)
        case .audio: return controls.state.liveAudio.contains { $0.audioItemId == item.refId }
        case .playlist: return controls.state.liveAudio.contains { $0.playlistId == item.refId }
        case .header, .info: return false
        }
    }

    private func rule(_ tint: Color?) -> some View {
        Rectangle()
            .fill(tint?.opacity(0.5) ?? Color(nsColor: .separatorColor).opacity(0.4))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private static let headerColors: [(name: String, hex: String)] = [
        ("Red", "#FF5F57FF"), ("Orange", "#FFA344FF"), ("Yellow", "#FFD60AFF"),
        ("Green", "#32D74BFF"), ("Blue", "#4B9BFFFF"), ("Purple", "#BF5AF2FF"),
    ]

    @ViewBuilder
    private func headerColorMenu(_ item: ServiceItem) -> some View {
        Menu("Color") {
            Toggle("None", isOn: Binding(
                get: { item.colorHex == nil },
                set: { _ in
                    model.setServiceHeaderColor(serviceID, itemID: item.id, colorHex: nil)
                }
            ))
            Divider()
            ForEach(Self.headerColors, id: \.hex) { color in
                Toggle(color.name, isOn: Binding(
                    get: { item.colorHex == color.hex },
                    set: { _ in
                        model.setServiceHeaderColor(
                            serviceID, itemID: item.id, colorHex: color.hex
                        )
                    }
                ))
            }
        }
    }

    private func importMediaIntoService() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                let before = Set(model.entries(in: .media).map(\.id))
                await model.importFiles(urls)
                let added = model.entries(in: .media).map(\.id).filter { !before.contains($0) }
                for id in added {
                    model.addServiceItem(serviceID, refID: id)
                }
            }
        }
    }

    private func hiddenGroupRow(count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showHidden ? 0 : -90))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHidden ? "Collapse" : "Expand")
            rule(nil)
            Text("HIDDEN (\(count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .tracking(0.6)
                .layoutPriority(1)
            rule(nil)
            Color.clear.frame(width: 14, height: 1)
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
    }

    private func hiddenRow(_ item: ServiceItem) -> some View {
        HStack(spacing: 8) {

            Text(item.itemKind == .header ? item.name.uppercased() : displayName(item))
                .font(item.itemKind == .header ? .caption2.weight(.semibold) : .body)
                .tracking(item.itemKind == .header ? 0.6 : 0)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if !runOnly {
                Button("Unhide") {
                    model.setServiceItemHidden(serviceID, itemID: item.id, hidden: false)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !runOnly {
                Button("Unhide") {
                    model.setServiceItemHidden(serviceID, itemID: item.id, hidden: false)
                }
                Divider()
                removeButton(item)
            }
        }
    }

    private func removeButton(_ item: ServiceItem) -> some View {
        Button("Remove from Service", role: .destructive) { requestRemoval([item.id]) }
    }

    private func requestRemoval(_ ids: [String]) {
        guard let service = try? model.service(serviceID) else { return }
        let removal = RunOrderSelection.removal(of: ids, in: service.items)
        guard removal.count > 0 else { return }
        for item in removal.local + removal.synced {
            model.removeServiceItem(serviceID, itemID: item.id)
        }
        deselect(removal.ids)
    }

    private func hide(_ ids: [String]) {
        for id in ids {
            model.setServiceItemHidden(serviceID, itemID: id, hidden: true)
        }
        deselect(ids)
    }

    private func deselect(_ ids: [String]) {
        let wasSelected = !selection.isDisjoint(with: ids)
        selection.subtract(ids)
        if !wasSelected, let current = selectedItemID, ids.contains(current) {
            selectedItemID = nil
        }
    }

    @ViewBuilder
    private func arrangementMenu(_ item: ServiceItem) -> some View {

        let arrangements = model.presentation(item.refId)?.arrangements
        if let arrangements, !arrangements.isEmpty {
            Menu("Arrangement") {
                Toggle(
                    "Default",
                    isOn: Binding(
                        get: { item.arrangementId?.isEmpty ?? true },
                        set: { _ in
                            model.setServiceItemArrangement(
                                serviceID, itemID: item.id, arrangementID: nil
                            )
                        }
                    )
                )
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(
                        arrangement.name,
                        isOn: Binding(
                            get: { item.arrangementId == arrangement.id },
                            set: { _ in
                                model.setServiceItemArrangement(
                                    serviceID, itemID: item.id, arrangementID: arrangement.id
                                )
                            }
                        )
                    )
                }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Menu {
                if let planAdds {
                    Button("Header…", systemImage: "textformat") { addingHeader = true }
                    Divider()
                    Button("Song", systemImage: "music.note", action: planAdds.song)
                    Button("Presentation", systemImage: "rectangle.on.rectangle", action: planAdds.deck)
                    Button("Slideshow", systemImage: "play.rectangle.on.rectangle", action: planAdds.slideshow)
                    Button("Video or Image…", systemImage: "film", action: planAdds.media)
                    Button("Message", systemImage: "text.book.closed", action: planAdds.message)
                    Divider()
                    Button("From Library…", systemImage: "books.vertical") { addingFromLibrary = true }
                } else {
                Button("New Slides Presentation") {
                    if let id = model.createEntity(in: .presentations) {
                        model.addServiceItem(serviceID, refID: id)
                    }
                }
                Button("New Media Item…") { importMediaIntoService() }
                Button("Header…") { addingHeader = true }
                Divider()
                Button("Add From Library…") { addingFromLibrary = true }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Add Item")
                }
            }
            Spacer()
            if let service = try? model.service(serviceID) {
                Text(itemCountLabel(service))
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(HopeMotion.ui, value: itemCountLabel(service))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func itemCountLabel(_ service: Service) -> String {
        let count = service.items.filter { $0.itemKind != .header }.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func arrangementName(_ item: ServiceItem) -> String? {

        guard let id = item.arrangementId, !id.isEmpty,
              let presentation = model.presentation(item.refId)
        else { return nil }
        return presentation.arrangements?.first { $0.id == id }?.name
    }
}

struct ServiceItemDetailView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let serviceID: String
    let itemID: String?

    var body: some View {
        if let itemID,
           let service = try? model.service(serviceID),
           let item = service.items.first(where: { $0.id == itemID }),
           item.itemKind != .header {
            switch item.itemKind {
            case .presentation:
                PresentGridView(
                    model: model, render: render, controls: controls,
                    presentationID: item.refId, arrangementId: item.arrangementId,
                    contextID: item.id,
                    serviceID: serviceID, serviceItem: item
                )
                .id(item.id)
            case .media:
                MediaFireView(model: model, controls: controls, mediaID: item.refId, serviceItemID: item.id)
            case .audio:
                AudioFireView(model: model, controls: controls, audioID: item.refId)
            case .playlist:
                PlaylistFireView(model: model, controls: controls, playlistID: item.refId)
            case .header:
                EmptyView()
            case .info:

                ContentUnavailableView(
                    "Not Linked", systemImage: "link",
                    description: Text("This item isn't linked to a presentation or media yet.")
                )
            }
        } else {
            HopeEmptyState(title: "No Item Selected", symbol: "rectangle.grid.3x2",
                           message: "Pick an item in the plan to see its slides.")
        }
    }
}

struct LibrarySearchSheet: View {
    let model: AppModel
    let serviceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var scopes: Set<LibrarySection> = []

    @State private var searchHits: [LibraryIndex.Hit] = []
    @FocusState private var fieldFocused: Bool

    private var addableTabs: [LibrarySection] { [.presentations, .media] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    TextField("Search the library", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                Menu {
                    ForEach(addableTabs) { section in
                        Toggle(section.displayName, isOn: Binding(
                            get: { scopes.isEmpty || scopes.contains(section) },
                            set: { include in
                                var next = scopes.isEmpty ? Set(addableTabs) : scopes
                                if include { next.insert(section) } else { next.remove(section) }
                                scopes = next.count == addableTabs.count ? [] : next
                            }
                        ))
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .imageScale(.small)
                        .foregroundStyle(scopes.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            resultsList
        }
        .frame(width: 380, height: 420)
        .onAppear { fieldFocused = true }
        .task(id: searchText) {
            searchHits = await model.search(searchText)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let hits = results
        List(hits, id: \.entry.id) { hit in
            Button {
                model.addServiceItem(serviceID, refID: hit.entry.id)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Glyph(
                        kind: hit.entry.kind == .presentation ? .presentations : .media,
                        size: 13
                    )
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.entry.name)
                        if let snippet = hit.snippet {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let used = hit.entry.lastUsedAt {
                        Text("Used \(used, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if hits.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search the Library", systemImage: "magnifyingglass",
                        description: Text("Matches names and lyrics; click a result to add it.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var results: [LibraryIndex.Hit] {
        let hits = searchText.isEmpty
            ? addableTabs.flatMap { section in
                model.entries(in: section).map { LibraryIndex.Hit(entry: $0, snippet: nil) }
            }
            : searchHits
        return hits.filter { hit in
            guard [.presentation, .media, .audio].contains(hit.entry.kind) else { return false }
            let section: LibrarySection = hit.entry.kind == .presentation ? .presentations : .media
            return scopes.isEmpty || scopes.contains(section)
        }
    }
}

/// Right-click › When Video Ends: stop, next slide, hold the last frame, or
/// fade to black. Choosing one stops the video looping.
struct VideoEndMenu: View {
    let model: AppModel
    let mediaID: String

    var body: some View {
        let current = model.media(mediaID)?.endAction
        Menu("When Video Ends") {
            ForEach([(MediaEndAction.stop, "Stop"), (.next, "Go to Next Slide"),
                     (.hold, "Hold Last Frame"), (.fadeToBlack, "Fade to Black")], id: \.0) { action, title in
                Toggle(title, isOn: Binding(
                    get: { current == action },
                    set: { _ in
                        model.updateMedia(mediaID) { media in
                            media.endAction = action
                            media.loops = false
                        }
                    }))
            }
            Divider()
            Toggle("Loop Instead", isOn: Binding(
                get: { model.media(mediaID)?.loops == true && current == nil },
                set: { _ in
                    model.updateMedia(mediaID) { media in
                        media.endAction = nil
                        media.loops = true
                    }
                }))
        }
    }
}

/// Right-click › Slideshow: how long each slide stays up, and what happens
/// after the last one (loop, or move on to the next item in the plan).
struct SlideshowMenu: View {
    let model: AppModel
    let presentationID: String

    var body: some View {
        let advance = model.presentation(presentationID)?.autoAdvance
        Menu("Slideshow") {
            Toggle("Off", isOn: Binding(get: { advance == nil }, set: { _ in set(nil) }))
            Divider()
            ForEach([3.0, 5, 8, 10, 15, 20, 30, 60], id: \.self) { seconds in
                Toggle("\(Int(seconds)) seconds per slide", isOn: Binding(
                    get: { advance?.delaySeconds == seconds },
                    set: { _ in set(AutoAdvance(delaySeconds: seconds, loopToStart: advance?.loopToStart ?? true)) }))
            }
            if let advance {
                Divider()
                Toggle("Loop back to the first slide", isOn: Binding(
                    get: { advance.loopToStart ?? false },
                    set: { _ in set(AutoAdvance(delaySeconds: advance.delaySeconds, loopToStart: true)) }))
                Toggle("Go to the next item after the last slide", isOn: Binding(
                    get: { !(advance.loopToStart ?? false) },
                    set: { _ in set(AutoAdvance(delaySeconds: advance.delaySeconds, loopToStart: false)) }))
            }
        }
    }

    private func set(_ advance: AutoAdvance?) {
        model.updatePresentation(presentationID) { $0.autoAdvance = advance }
    }
}

/// What the plan window's add menu can make.
struct PlanAddActions {
    var song: () -> Void
    var deck: () -> Void
    var slideshow: () -> Void
    var media: () -> Void
    var message: () -> Void
}
