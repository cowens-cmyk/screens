import AVFoundation
import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// The slide editor that's open in the main window, so the Media Library
/// (its own window, where the editor's focused value doesn't reach) can put
/// a background on the slide being edited.
@MainActor @Observable
final class SlideEditorRegistry {
    static let shared = SlideEditorRegistry()

    private(set) weak var editor: SlideEditorModel?

    func note(_ editor: SlideEditorModel?) {
        self.editor = editor
    }

    func forget(_ editor: SlideEditorModel?) {
        if let editor, self.editor === editor { self.editor = nil }
    }

    /// The editor, when it has a slide (not a theme) to take a background.
    var backgroundTarget: SlideEditorModel? {
        guard let editor, !editor.isThemeEditor, editor.selectedSlideID != nil else { return nil }
        return editor
    }
}

/// Right-click › When It Ends on a video, wherever it's shown: the plan, the
/// fire view, the library and the Media Library. The category's default is
/// marked; choosing it puts the video back on its category's default, so
/// moving it to another category changes it too.
struct WhenItEndsMenu: View {
    let model: AppModel
    let mediaID: String

    var body: some View {
        if let item = model.media(mediaID), item.mediaKind == .video {
            let current = item.endChoice
            let fallback = item.defaultEndChoice
            Menu("When It Ends") {
                ForEach(MediaEndChoice.allCases) { choice in
                    Toggle(choice == fallback ? "\(choice.title) (Default)" : choice.title, isOn: Binding(
                        get: { current == choice },
                        set: { _ in
                            let chosen: MediaEndChoice? = choice == fallback ? nil : choice
                            model.updateMedia(mediaID) { $0.choose(chosen) }
                        }))
                }
            }
        }
    }
}

/// Window › Media Library (⇧⌘M), or Media Library in the Media tab of the
/// library: worship backgrounds, countdowns, videos, sermon slides, images
/// and audio, each a folder in the library. Drag a tile onto the plan to add
/// it, or onto a slide to make it the background; drop files on a category
/// to import them there.
///
/// Given `picking`, the same browser picks pictures and videos for new
/// slides (Add Slide › From Media Library…): click to pick, double-click to
/// add one, and nothing is renamed, moved or dragged from it.
struct MediaLibraryView: View {
    let model: AppModel
    var picking: MediaLibraryPicking? = nil
    /// The Media tab of the main window: the categories sit beside the grid
    /// in the page itself. A split view there would reach up under the
    /// window's toolbar and fold its sidebar away.
    var embedded = false

    @Environment(\.runOnly) private var runOnly
    @Environment(\.openWindow) private var openWindow

    @AppStorage("mediaLibrary.category") private var shownRaw = Shown.all.rawValue
    @AppStorage("mediaLibrary.tileWidth") private var tileWidth = 180.0

    @State private var searchText = ""
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var previewID: String?
    @State private var dropTarget: String?
    @State private var renameTarget: LibraryIndex.Entry?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryIndex.Entry?
    @State private var deleteUsedCount = 0
    @State private var settingsTarget: MediaSettingsTarget?
    @State private var picked: [String] = []

    /// All Media or one category; stored by name so the window opens where
    /// it was left.
    enum Shown: Hashable {
        case all
        case category(MediaLibraryCategory)

        var rawValue: String {
            switch self {
            case .all: "all"
            case .category(let category): category.rawValue
            }
        }

        init(rawValue: String) {
            self = MediaLibraryCategory(rawValue: rawValue).map(Shown.category) ?? .all
        }

        var title: String {
            switch self {
            case .all: "All Media"
            case .category(let category): category.title
            }
        }
    }

    private var shown: Shown {
        let stored = Shown(rawValue: shownRaw)
        // Music can't be a slide.
        return picking != nil && stored == .category(.audio) ? .all : stored
    }

    /// The categories on the side; picking leaves out Audio.
    private var categories: [MediaLibraryCategory] {
        MediaLibraryCategory.allCases.filter { picking == nil || $0 != .audio }
    }

    var body: some View {
        let media = model.entries(in: .media)
        let audio = model.entries(in: .audio)
        let entries = searched(members(of: shown, media: media, audio: audio))
        Group {
            if embedded {
                HStack(spacing: 0) {
                    sidebar(media: media, audio: audio)
                        .scrollContentBackground(.hidden)
                        .frame(width: 244)
                    Divider()
                    detail(entries: entries)
                }
            } else {
                NavigationSplitView {
                    sidebar(media: media, audio: audio)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                } detail: {
                    detail(entries: entries)
                        .navigationTitle("Media Library")
                        .navigationSubtitle(shown.title)
                }
                .frame(minWidth: 720, minHeight: 440)
            }
        }
        .frame(width: picking == nil ? nil : 880, height: picking == nil ? nil : 580)
        .task(id: hoveredID) {
            // A preview starts only once the pointer rests on a tile, so
            // sweeping across the grid never opens a video.
            previewID = nil
            guard let id = hoveredID else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { previewID = id }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renameTarget { model.rename(renameTarget, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleteTarget?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deleteTarget { model.delete(deleteTarget) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if deleteUsedCount > 0 {
                Text("Used in \(deleteUsedCount) place\(deleteUsedCount == 1 ? "" : "s"). Each shows a missing-media warning until the file is restored or replaced. This can't be undone.")
            } else {
                Text("This can't be undone.")
            }
        }
        .sheet(item: $settingsTarget) { target in
            MediaSettingsSheet(model: model, mediaID: target.id)
        }
    }

    // MARK: Categories

    private func sidebar(media: [LibraryIndex.Entry], audio: [LibraryIndex.Entry]) -> some View {
        List {
            categoryRow(.all, count: members(of: .all, media: media, audio: audio).count, glyph: "square.grid.2x2")
            Section("Categories") {
                ForEach(categories) { category in
                    categoryRow(
                        .category(category),
                        count: members(of: .category(category), media: media, audio: audio).count,
                        glyph: Self.symbol(for: category))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func categoryRow(_ row: Shown, count: Int, glyph: String) -> some View {
        Button {
            shownRaw = row.rawValue
            selectedID = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(row.title)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle.standard(CornerStandard.element)
                .fill(rowFill(row))
                .padding(.horizontal, 4))
        .onDrop(of: [.fileURL, .plainText], delegate: MediaLibraryDropDelegate(
            enabled: !runOnly,
            targeted: { on in
                if on { dropTarget = row.rawValue } else if dropTarget == row.rawValue { dropTarget = nil }
            },
            files: { urls in Task { await importFiles(urls, into: row) } },
            entryID: { id in file(id, into: row) }))
    }

    private func rowFill(_ row: Shown) -> Color {
        if dropTarget == row.rawValue { return Color.accentColor.opacity(0.35) }
        return shown == row ? Color.primary.opacity(0.1) : .clear
    }

    static func symbol(for category: MediaLibraryCategory) -> String {
        switch category {
        case .worshipBackgrounds: "sparkles.tv"
        case .countdowns: "timer"
        case .videos: "film"
        case .sermonSlides: "text.below.photo"
        case .announcements: "megaphone"
        case .images: "photo"
        case .audio: "music.note"
        }
    }

    private func members(of row: Shown, media: [LibraryIndex.Entry], audio: [LibraryIndex.Entry]) -> [LibraryIndex.Entry] {
        switch row {
        case .all: picking == nil ? media + audio : media
        case .category(.audio): audio
        case .category(let category):
            media.filter { MediaLibraryCategory.containing(folder: $0.subkind) == category }
        }
    }

    private func searched(_ entries: [LibraryIndex.Entry]) -> [LibraryIndex.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        guard picking != nil else {
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // Picking for slides, what was used last comes first.
        return matching.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (usedA?, usedB?): usedA > usedB
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: Grid

    private func detail(entries: [LibraryIndex.Entry]) -> some View {
        VStack(spacing: 0) {
            header(count: entries.count)
            Divider()
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.4), spacing: 14)],
                    spacing: 16
                ) {
                    ForEach(entries) { entry in
                        tile(entry)
                    }
                }
                .padding(16)
            }
            .overlay {
                if entries.isEmpty { emptyState }
            }
            .background(dropTarget == "grid" ? Color.accentColor.opacity(0.08) : .clear)
            .onDrop(of: [.fileURL, .plainText], delegate: MediaLibraryDropDelegate(
                enabled: !runOnly,
                targeted: { on in
                    if on { dropTarget = "grid" } else if dropTarget == "grid" { dropTarget = nil }
                },
                files: { urls in Task { await importFiles(urls, into: shown) } },
                entryID: { id in file(id, into: shown) }))
            if let picking {
                Divider()
                pickBar(picking)
            } else if let summary = model.lastImportSummary {
                Divider()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func pickBar(_ picking: MediaLibraryPicking) -> some View {
        HStack {
            Text("Click to pick, double-click to add one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: picking.cancel)
                .keyboardShortcut(.cancelAction)
            Button(picked.count > 1 ? "Add \(picked.count) Slides" : "Add Slide") { picking.add(picked) }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
        }
        .padding(10)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            Text(shown.title)
                .font(.headline)
            Text("\(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle.standard(CornerStandard.element))
            .frame(width: 200)
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Slider(value: $tileWidth, in: 120...320)
                    .controlSize(.small)
                    .frame(width: 110)
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .help("Thumbnail size")
            if !runOnly {
                Button {
                    presentImportPanel()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isImporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "Nothing in \(shown.title)" : "No Matches", systemImage: shownSymbol)
        } description: {
            if !searchText.isEmpty {
                Text("Nothing here is named \u{201C}\(searchText)\u{201D}.")
            } else if !runOnly {
                Text(emptyInvite)
            }
        } actions: {
            if searchText.isEmpty, !runOnly {
                Button("Import…") { presentImportPanel() }
            }
        }
    }

    private var shownSymbol: String {
        if case .category(let category) = shown { Self.symbol(for: category) } else { "photo.on.rectangle.angled" }
    }

    private var emptyInvite: String {
        switch shown {
        case .all: "Drop videos, images or music here, or use Import."
        case .category(.worshipBackgrounds): "Drop worship backgrounds here. They loop while they're up."
        case .category(.countdowns): "Drop countdown videos here. The plan's countdown is chosen from these."
        case .category(.videos): "Drop videos here. They play once."
        case .category(.sermonSlides): "Drop sermon slide images here. A PDF or Keynote file becomes a presentation."
        case .category(.announcements): "Drop announcement images here. Event artwork from hopejc.org is added here too."
        case .category(.images): "Drop images here."
        case .category(.audio): "Drop music here."
        }
    }

    @ViewBuilder
    private func tile(_ entry: LibraryIndex.Entry) -> some View {
        let order = picked.firstIndex(of: entry.id)
        let base = MediaLibraryTile(
            model: model, entry: entry,
            previewing: previewID == entry.id,
            selected: picking == nil ? selectedID == entry.id : order != nil)
        .overlay(alignment: .topLeading) {
            if let order, picked.count > 1 {
                Text("\(order + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.accentColor))
                    .padding(5)
            }
        }
        .onHover { inside in
            if inside {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        if let picking {
            base
                .onTapGesture(count: 2) { picking.add([entry.id]) }
                .onTapGesture {
                    if let order { picked.remove(at: order) } else { picked.append(entry.id) }
                }
        } else {
            base
                .onTapGesture { selectedID = entry.id }
                // Dropped on the plan or a slide it changes them, so not in Run-Only.
                .draggablePayload(runOnly ? nil : entry.id)
                .contextMenu { menu(entry) }
        }
    }

    // MARK: Right-click

    @ViewBuilder
    private func menu(_ entry: LibraryIndex.Entry) -> some View {
        let item = entry.kind == .media ? model.media(entry.id) : nil
        if !runOnly {
            Button("Add to Plan") { model.addToCurrentService(entry) }
                .disabled(model.currentServiceID == nil)
            if let item, item.libraryCategory == .worshipBackgrounds || item.mediaKind == .image {
                let target = SlideEditorRegistry.shared.backgroundTarget
                Button("Use as Background") { target?.setBackground(mediaID: entry.id) }
                    .disabled(target == nil)
                    .help(target == nil ? "Open a slide in Edit first" : "Puts it behind the slide being edited")
            }
            if item?.mediaKind == .video {
                Divider()
                WhenItEndsMenu(model: model, mediaID: entry.id)
            }
            Divider()
            if item != nil {
                Button("Media Settings…") { settingsTarget = MediaSettingsTarget(id: entry.id) }
            }
            Button("Rename…") {
                renameText = entry.name
                renameTarget = entry
            }
            if entry.kind == .media {
                let current = MediaLibraryCategory.containing(folder: entry.subkind)
                Menu("Move to") {
                    ForEach(MediaLibraryCategory.allCases.filter { $0 != .audio }) { category in
                        Button(category.title) { model.moveToFolder(entry, folder: category.folder) }
                            .disabled(category == current)
                    }
                }
            }
        }
        Button("Show in Finder") {
            if let url = model.fileURL(of: entry) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        if !runOnly {
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(entry) }
        }
    }

    private func requestDelete(_ entry: LibraryIndex.Entry) {
        Task {
            deleteUsedCount = entry.kind == .media ? await model.mediaReferenceDocumentCount(of: [entry.id]) : 0
            deleteTarget = entry
        }
    }

    // MARK: Filing and importing

    /// A tile dropped on a category moves there; Audio holds only music.
    private func file(_ id: String, into row: Shown) -> Bool {
        guard case .category(let category) = row, let folder = category.folder,
              let entry = model.indexEntry(id), entry.kind == .media,
              MediaLibraryCategory.containing(folder: entry.subkind) != category
        else { return false }
        model.moveToFolder(entry, folder: folder)
        return true
    }

    /// Files dropped on a category are filed there. Dropped on All Media,
    /// each goes where it belongs: videos to Videos, pictures to Images,
    /// music to Audio. PDFs and Keynote decks become presentations, as they
    /// do anywhere else.
    private func importFiles(_ urls: [URL], into row: Shown) async {
        switch row {
        case .category(let category):
            await model.importFiles(urls, placement: Self.placement(category))
        case .all:
            var byCategory: [MediaLibraryCategory?: [URL]] = [:]
            for url in urls {
                byCategory[MediaLibraryCategory.forImportedFile(url), default: []].append(url)
            }
            for (category, files) in byCategory {
                if let category {
                    await model.importFiles(files, placement: Self.placement(category))
                } else {
                    await model.importFiles(files)
                }
            }
        }
    }

    private static func placement(_ category: MediaLibraryCategory) -> LibraryHome.Placement {
        // Music isn't filed under a media folder: an empty path leaves it
        // where imports usually land.
        .drive(viewing: LibraryHome.Viewed(kind: .media, area: .team, path: category.folder ?? ""))
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .video, .audio, .pdf]
            + [UTType(filenameExtension: "key")].compactMap { $0 }
        let target = shown
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await importFiles(urls, into: target) }
        }
    }
}

/// What the Media Library does when it's picking media for new slides.
struct MediaLibraryPicking {
    /// The picked media ids, in the order they were picked.
    let add: ([String]) -> Void
    let cancel: () -> Void
}

/// One tile: the poster (a muted preview while the pointer rests on a
/// video), the name, the length, and a loop badge on what loops.
private struct MediaLibraryTile: View {
    let model: AppModel
    let entry: LibraryIndex.Entry
    let previewing: Bool
    let selected: Bool

    var body: some View {
        let item = entry.kind == .media ? model.media(entry.id) : nil
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color.black
                if let item {
                    PosterImage(model: model, mediaId: item.id)
                    if previewing, item.mediaKind == .video, !model.isMediaFileMissing(item),
                       let url = model.blobs?.url(forHash: item.fileHash) {
                        MediaHoverPreview(url: url)
                            .transition(.opacity)
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            .overlay(alignment: .topTrailing) {
                if item?.playsLooping == true {
                    Image(systemName: "repeat")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(5)
                        .help("Loops")
                }
            }
            .overlay {
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.4),
                        lineWidth: selected ? 2 : 1)
            }
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let length = Self.length(item?.durationSeconds ?? model.audio(entry.id)?.durationSeconds) {
                    Text(length)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: previewing)
    }

    static func length(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// A muted, looping preview for the one tile under the pointer. Decoded
/// small and torn down the moment the pointer leaves, so the grid costs
/// nothing while nobody's pointing at it.
private struct MediaHoverPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(url: url)
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.stop()
    }

    final class PreviewView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            let item = AVPlayerItem(url: url)
            item.preferredMaximumResolution = CGSize(width: 640, height: 360)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: item)
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            wantsLayer = true
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }
    }
}

/// Files or a library tile dropped on the Media Library. Read from the drag
/// pasteboard as the slide lists do, so a tile's id and Finder's files both
/// arrive whole.
private struct MediaLibraryDropDelegate: DropDelegate {
    let enabled: Bool
    let targeted: (Bool) -> Void
    let files: ([URL]) -> Void
    let entryID: (String) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.fileURL, .plainText])
    }

    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        let pasteboard = NSPasteboard(name: .drag)
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            files(urls)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return entryID(text)
        }
        return false
    }
}
