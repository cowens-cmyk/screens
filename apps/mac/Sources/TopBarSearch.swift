import AppKit
import PresenterCore
import SwiftUI

/// One thing the search found: an item in the open plan, or something in
/// the library (a song or presentation, a video, picture or sound).
struct TopBarSearchResult: Identifiable, Equatable {
    enum Target: Equatable {
        case planItem(String)
        case library(LibraryIndex.Entry)
    }

    let id: String
    let target: Target
    let title: String
    let detail: String?
    let symbol: String
    let color: Color

    var isLibrary: Bool { if case .library = target { true } else { false } }
}

struct TopBarSearchSection: Identifiable, Equatable {
    let title: String
    let results: [TopBarSearchResult]
    var id: String { title }
}

/// The search behind the top bar's Search button and Find (⌘F), like
/// Spotlight: the button grows into a large field over the window, results
/// grow down under it, and Esc or a click outside shrinks it back.
///
/// What keeps it reliable lives here rather than in the views:
/// - While it is open the window's keys belong to it. The show's key
///   handling and the editors' monitors ask `isOpen` and stand aside, and a
///   monitor of its own takes the arrows, Return and Esc. Anything typed
///   before the field has focus is added to the query and focus asked for
///   again, so no keystroke is lost and none can fire a slide.
/// - An open asked for while the last close is still shrinking waits for it
///   to settle: two copies of the field on screen at once is what makes a
///   matched-geometry morph flicker.
/// - Library results for one query replace the last query's only when they
///   arrive, so rows don't blink empty between keystrokes.
@MainActor
@Observable
final class TopBarSearch {
    /// Read by the show's key handling and the editors' key monitors, all
    /// on the main thread, some from code AppKit doesn't mark as such.
    nonisolated(unsafe) private(set) static var isOpen = false
    /// The window the search is open in; other windows keep their keys.
    nonisolated(unsafe) private static weak var openWindow: NSWindow?

    /// Whether keys in `window` belong to the search right now.
    nonisolated static func blocks(_ window: NSWindow?) -> Bool {
        isOpen && window != nil && window === openWindow
    }

    static let placeholder = "Search the plan and the library"

    private(set) var shown = false
    /// The field's text, the results and the footer; they fade in once the
    /// shape has mostly grown, and out before it shrinks.
    private(set) var revealed = false
    private(set) var query = ""
    private(set) var sections: [TopBarSearchSection] = []
    private(set) var selectedID: String?
    private(set) var searching = false
    /// Bumped whenever the field should take focus.
    private(set) var focusRequests = 0
    private(set) var reduceMotion = false
    /// Whether ⌘Return can add the selected library result to a plan.
    private(set) var canAdd = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var planItems: [ServiceItem] = []
    @ObservationIgnored private var hits: [LibraryIndex.Hit] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOpen: Task<Void, Never>?
    @ObservationIgnored private var settledAt: TimeInterval = 0
    @ObservationIgnored private var monitor: Any?
    /// What Return (add false) and ⌘Return (add true) do with a result.
    @ObservationIgnored var perform: (TopBarSearchResult, _ add: Bool) -> Void = { _, _ in }

    static func morph(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    var results: [TopBarSearchResult] { sections.flatMap(\.results) }

    // MARK: Opening and closing

    func toggle(model: AppModel, plan: Service?, reduceMotion: Bool) {
        if shown { close() } else { open(model: model, plan: plan, reduceMotion: reduceMotion) }
    }

    func open(model: AppModel, plan: Service?, reduceMotion: Bool) {
        pendingOpen?.cancel()
        pendingOpen = nil
        guard !shown else {
            focusRequests += 1
            return
        }
        let wait = settledAt - ProcessInfo.processInfo.systemUptime
        if wait > 0 {
            pendingOpen = Task { [weak self, weak model] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, let model else { return }
                self.open(model: model, plan: plan, reduceMotion: reduceMotion)
            }
            return
        }
        self.model = model
        self.reduceMotion = reduceMotion
        planItems = plan?.items ?? []
        canAdd = plan != nil
        query = ""
        hits = []
        sections = []
        selectedID = nil
        searching = false
        Self.openWindow = NSApp.keyWindow ?? NSApp.mainWindow
        Self.isOpen = true
        installMonitor()
        withAnimation(Self.morph(reduced: reduceMotion)) { shown = true }
        // On the next pass, once the panel is on screen faded out: changed
        // in the same pass that inserts it, it would just appear.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shown, !self.revealed else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.18).delay(0.08)) {
                self.revealed = true
            }
        }
        focusRequests += 1
    }

    func close() {
        pendingOpen?.cancel()
        pendingOpen = nil
        guard shown else { return }
        Self.isOpen = false
        removeMonitor()
        searchTask?.cancel()
        withAnimation(.easeIn(duration: 0.08)) { revealed = false }
        withAnimation(Self.morph(reduced: reduceMotion)) { shown = false }
        settledAt = ProcessInfo.processInfo.systemUptime + (reduceMotion ? 0.2 : 0.45)
    }

    // MARK: Query and results

    func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        if trimmed.isEmpty {
            hits = []
            searching = false
            refresh()
            return
        }
        refresh()
        searching = true
        searchTask = Task { [weak self] in
            // A short pause, so a fast typist's every letter isn't a search.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let model = self?.model else { return }
            let found = await model.search(trimmed)
            guard !Task.isCancelled, let self,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.hits = found
            self.searching = false
            withAnimation(self.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { self.refresh() }
        }
    }

    private func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sections = []
            selectedID = nil
            return
        }
        var next: [TopBarSearchSection] = []

        let planMatches = planItems
            .filter { !$0.name.isEmpty && $0.name.localizedStandardContains(trimmed) }
            .prefix(6)
            .map { item in
                let presentation = item.itemKind == .presentation ? model?.presentation(item.refId) : nil
                let kind = HopeStyle.kind(of: item, presentation: presentation)
                return TopBarSearchResult(
                    id: "plan:\(item.id)", target: .planItem(item.id), title: item.name,
                    detail: nil, symbol: kind.symbol, color: kind.color)
            }
        if !planMatches.isEmpty { next.append(TopBarSearchSection(title: "In This Plan", results: planMatches)) }

        var shows: [TopBarSearchResult] = []
        var media: [TopBarSearchResult] = []
        for hit in hits {
            let entry = hit.entry
            switch entry.kind {
            case .presentation where shows.count < 8:
                let song = model?.presentation(entry.id)?.presentationKind == .song
                shows.append(TopBarSearchResult(
                    id: "library:\(entry.id)", target: .library(entry), title: entry.name, detail: hit.snippet,
                    symbol: song ? "music.note" : "rectangle.on.rectangle",
                    color: song ? HopeStyle.stagePurple : HopeStyle.blue))
            case .media where media.count < 6, .audio where media.count < 6:
                media.append(TopBarSearchResult(
                    id: "library:\(entry.id)", target: .library(entry), title: entry.name, detail: hit.snippet,
                    symbol: entry.kind == .audio ? "waveform" : "photo.on.rectangle",
                    color: entry.kind == .audio ? Color.pink : HopeStyle.lightBlue))
            default:
                continue
            }
        }
        if !shows.isEmpty { next.append(TopBarSearchSection(title: "Songs & Presentations", results: shows)) }
        if !media.isEmpty { next.append(TopBarSearchSection(title: "Media", results: media)) }

        sections = next
        let ids = next.flatMap(\.results).map(\.id)
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
    }

    // MARK: Choosing

    func select(_ id: String) { selectedID = id }

    func move(by step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        selectedID = ids[min(max(index + step, 0), ids.count - 1)]
    }

    /// Return opens the selected result; ⌘Return adds a library result to
    /// the open plan (a plan item is already there, so it just shows it).
    func activate(_ id: String? = nil, add: Bool) {
        guard let result = results.first(where: { $0.id == (id ?? selectedID) }) else { return }
        close()
        perform(result, add && canAdd && result.isLibrary)
    }

    // MARK: Keys

    /// The field's focus as SwiftUI sees it, set by the panel: true once the
    /// field really is first responder.
    @ObservationIgnored var fieldHasFocus = false

    /// The search field's editor, when it has the keys.
    private func fieldEditor(in window: NSWindow?) -> NSTextView? {
        guard fieldHasFocus, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    /// A field taking focus selects all its text, and the next key would
    /// replace what was typed before it had focus; the caret goes after it.
    func moveCaretToEnd() {
        guard let editor = fieldEditor(in: Self.openWindow), !editor.hasMarkedText() else { return }
        let end = NSRange(location: (editor.string as NSString).length, length: 0)
        if editor.selectedRange() != end { editor.setSelectedRange(end) }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the key was the search's.
    private func handle(_ event: NSEvent) -> Bool {
        guard shown, Self.blocks(event.window), let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil else { return false }
        // Composing (Japanese, Chinese, accents): the text system's keys.
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let inField = fieldEditor(in: window) != nil
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.keyCode {
        case 53: close(); return true                                  // Esc
        case 125: move(by: 1); return true                             // ↓
        case 126: move(by: -1); return true                            // ↑
        case 36, 76: activate(add: flags.contains(.command)); return true // Return, Enter
        default: break
        }
        if inField { return false }
        // Menu shortcuts (⌘F again, ⌘Q) still reach the menus.
        if flags.contains(.command) || flags.contains(.control) { return false }
        // The field hasn't got focus yet: keep the typing, and ask again.
        if event.keyCode == 51 {
            updateQuery(String(query.dropLast()))
        } else if let typed = event.characters,
                  typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700 ... 0xF8FF).contains($0.value) }) {
            updateQuery(query + typed)
        }
        focusRequests += 1
        // Everything else is swallowed too: an arrow or Space here must
        // never reach the slides under the search.
        return true
    }
}

// MARK: The button

enum TopBarSearchIDs {
    static let shape = "topbar.search.shape"
    static let icon = "topbar.search.icon"
}

/// The round Search button at the left of the top bar. It is the field's
/// starting shape: while the search is open it leaves an empty space the
/// same size, so nothing in the bar moves.
struct TopBarSearchButton: View {
    let open: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    private static let corner = TopBarMetrics.searchSize / 2

    var body: some View {
        ZStack {
            if !open {
                Button(action: action) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .matchedGeometryEffect(id: TopBarSearchIDs.icon, in: namespace)
                        .frame(width: TopBarMetrics.searchSize, height: TopBarMetrics.searchSize)
                        .background {
                            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                                .fill(TopBarSearchPanel.surface)
                                .matchedGeometryEffect(id: TopBarSearchIDs.shape, in: namespace)
                        }
                        .overlay(Circle().strokeBorder(TopBarMetrics.groupStroke, lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(TopBarButtonStyle())
                .help("Search the plan and the library (⌘F)")
                .accessibilityLabel("Search")
            }
        }
        .frame(width: TopBarMetrics.searchSize, height: TopBarMetrics.searchSize)
    }
}

// MARK: The overlay

/// Over the whole window while the search is open: the dimmed, softly
/// blurred window, and the field with its results near the top.
struct TopBarSearchOverlay: View {
    let search: TopBarSearch
    let namespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .top) {
            if search.shown {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.55)
                    Color.black.opacity(0.32)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { search.close() }
                .transition(.opacity)

                // Solid from its first frame, growing out of the button,
                // which fades under it; closing, it fades as it shrinks
                // back while the button fades in. With Reduce Motion it
                // only fades.
                TopBarSearchPanel(search: search, namespace: namespace)
                    .padding(.top, TopBarMetrics.height + 40)
                    .padding(.horizontal, 24)
                    .transition(search.reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The field and, once something is typed, the results in their groups and
/// a row of the keys that work.
struct TopBarSearchPanel: View {
    let search: TopBarSearch
    let namespace: Namespace.ID

    @FocusState private var focused: Bool

    static let width: CGFloat = 640
    static let fieldHeight: CGFloat = 56
    static let corner: CGFloat = 22
    static let rowHeight: CGFloat = 36
    static let headerHeight: CGFloat = 26
    static let maxResultsHeight: CGFloat = 400
    /// The button's fill and the field's under it: the same, so the shape
    /// reads as one thing while it grows.
    static let surface = Color(red: 0.13, green: 0.135, blue: 0.15)

    private var hasQuery: Bool { !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Worked out from the counts rather than measured, so the panel's
    /// height animates with the results instead of chasing a measurement.
    private var resultsHeight: CGFloat {
        if search.sections.isEmpty { return 56 }
        let rows = search.sections.reduce(CGFloat(0)) { $0 + Self.headerHeight + CGFloat($1.results.count) * Self.rowHeight }
        return min(rows + 12, Self.maxResultsHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if hasQuery {
                Divider().opacity(0.6)
                results
                    .frame(height: resultsHeight)
                Divider().opacity(0.6)
                footer
            }
        }
        .frame(width: Self.width)
        .background {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(Self.surface.opacity(0.92))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                // With Reduce Motion the panel fades in place instead of
                // growing out of the button.
                .matchedGeometryEffect(
                    id: search.reduceMotion ? "topbar.search.still" : TopBarSearchIDs.shape, in: namespace)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                .opacity(search.revealed ? 1 : 0))
        // Not clipped: while it grows, the shape is out at the button's
        // frame, beyond the panel's own.
        .shadow(color: .black.opacity(search.revealed ? 0.45 : 0), radius: 30, y: 14)
        .animation(TopBarSearch.morph(reduced: search.reduceMotion), value: hasQuery)
        .animation(TopBarSearch.morph(reduced: search.reduceMotion), value: resultsHeight)
        .onAppear(perform: takeFocus)
        .onChange(of: search.focusRequests) { takeFocus() }
        .onChange(of: focused) { _, now in focusChanged(now) }
        .onDisappear { search.fieldHasFocus = false }
    }

    private func takeFocus() {
        focused = true
        // Again once the field is in the window: the first can land while
        // it's still being inserted.
        DispatchQueue.main.async { focused = true }
    }

    private func focusChanged(_ now: Bool) {
        search.fieldHasFocus = now
        if now { DispatchQueue.main.async { search.moveCaretToEnd() } }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .matchedGeometryEffect(
                    id: search.reduceMotion ? "topbar.search.still.icon" : TopBarSearchIDs.icon, in: namespace)
            Group {
                TextField(TopBarSearch.placeholder, text: Binding(get: { search.query }, set: { search.updateQuery($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($focused)
                if !search.query.isEmpty {
                    Button { search.updateQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .opacity(search.revealed ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.fieldHeight)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if search.sections.isEmpty {
            Text(search.searching ? "Searching…" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(search.revealed ? 1 : 0)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let ordered = search.results.map(\.id)
                        ForEach(search.sections) { section in
                            Text(section.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                            ForEach(section.results) { result in
                                TopBarSearchRow(
                                    result: result,
                                    selected: result.id == search.selectedID,
                                    order: ordered.firstIndex(of: result.id) ?? 0,
                                    canAdd: search.canAdd,
                                    reduceMotion: search.reduceMotion
                                ) { add in search.activate(result.id, add: add) }
                                .id(result.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.automatic)
                .onChange(of: search.selectedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            .opacity(search.revealed ? 1 : 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let selected = search.results.first { $0.id == search.selectedID }
        return HStack(spacing: 14) {
            hint("↑↓", "Move")
            hint("↩", selected?.isLibrary == true ? "Open in Editor" : "Show")
            if search.canAdd {
                hint("⌘↩", "Add to Plan")
                    .opacity(selected?.isLibrary == true ? 1 : 0.4)
            }
            Spacer(minLength: 0)
            hint("esc", "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .opacity(search.revealed ? 1 : 0)
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 16)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(title)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

/// One result. New rows fade and drop in a little after each other; rows
/// that stay while the query changes don't replay it.
private struct TopBarSearchRow: View {
    let result: TopBarSearchResult
    let selected: Bool
    let order: Int
    let canAdd: Bool
    let reduceMotion: Bool
    let activate: (_ add: Bool) -> Void

    @State private var appeared = false
    @State private var hovering = false

    var body: some View {
        Button { activate(NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: 10) {
                Image(systemName: result.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.white : result.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if let detail = result.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Text(result.isLibrary ? "Open in Editor" : "Show")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TopBarSearchPanel.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? HopeStyle.blue : Color.white.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(result.isLibrary && canAdd ? "Click to open in the editor, ⌘-click to add to the plan" : "")
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -4)
        .onAppear {
            let delay = Double(min(order, 8)) * 0.025
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18).delay(delay)) {
                appeared = true
            }
        }
    }
}
