import AppKit
import ImageIO
import PresenterCore
import SwiftUI

/// Settings › Integrations › Website: hopejc.org's events in the pre-service
/// slideshow. The choices are church-wide (any Mac can change them), and
/// every Mac does the adding and removing.
struct WebsiteEventsSettingsForm: View {
    let model: AppModel?
    @State private var sync = WebsiteEventSync.shared
    /// The event whose picture is being picked from the Media Library.
    @State private var picking: WebsiteEvents.Shown?

    private var settings: WebsiteEventSettings? { model?.slideBuilding.websiteEvents }

    var body: some View {
        Form {
            Section {
                SettingsToggle("website.events", isOn: switchBinding(.preService))
                SettingsToggle("website.students", isOn: switchBinding(.students))
                SettingsRow("website.window") {
                    Stepper(value: Binding(
                        get: { WebsiteEvents.Options(settings).windowDays },
                        set: { days in sync.update { $0.windowDays = days } }),
                        in: WebsiteEvents.windowDayRange) {
                        Text("\(WebsiteEvents.Options(settings).windowDays) days").monospacedDigit()
                    }
                    .fixedSize()
                }
                SettingsRow("website.removeAt") {
                    Picker("", selection: Binding(
                        get: { settings?.removeAtEnd ?? false },
                        set: { atEnd in sync.update { $0.removeAtEnd = atEnd ? true : nil } })) {
                        Text("When it starts").tag(false)
                        Text("When it ends").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("website.sync") {
                    HStack(spacing: 12) {
                        Text(lastSyncText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button(sync.isWorking ? "Syncing…" : "Sync Now") { sync.syncNow() }
                            .disabled(sync.isWorking)
                    }
                }
            } header: {
                Text("hopejc.org Events")
            } footer: {
                Text(footer)
            }
            eventList(
                "website.list", header: SettingsHeader(id: "website.list"), rows: rows, slideshow: .preService,
                empty: sync.events == nil ? "Events haven't been read yet." : "No events in the next \(WebsiteEvents.Options(settings).windowDays) days.")
            eventList(
                "website.studentsList", header: SettingsHeader(id: "website.studentsList"), rows: studentRows, slideshow: .students,
                empty: sync.studentEvents == nil ? "Events haven't been read yet." : "No Hope Students events in the next \(WebsiteEvents.Options(settings).windowDays) days.")
        }
        .settingsForm()
        .onAppear {
            if sync.lastFetched.map({ Date().timeIntervalSince($0) > 60 }) ?? true { sync.syncNow() }
        }
        .sheet(item: Binding(get: { picking.map { PickTarget(shown: $0) } }, set: { picking = $0?.shown })) { target in
            if let model {
                MediaSlidePickerSheet(model: model) { ids in
                    if let id = ids.first { choose(id, for: target.shown) }
                }
            }
        }
    }

    private struct PickTarget: Identifiable {
        let shown: WebsiteEvents.Shown
        var id: String { shown.key }
    }

    private func switchBinding(_ slideshow: WebsiteEvents.Slideshow) -> Binding<Bool> {
        Binding(
            get: { WebsiteEvents.isEnabled(settings, for: slideshow) },
            set: { on in sync.update { $0 = WebsiteEvents.setting($0, enabled: on, for: slideshow) } })
    }

    @ViewBuilder
    private func eventList(
        _ id: String, header: SettingsHeader, rows: [WebsiteEvents.Shown], slideshow: WebsiteEvents.Slideshow, empty: String
    ) -> some View {
        Section {
            if !WebsiteEvents.isEnabled(settings, for: slideshow) {
                Text("Turned off: nothing is added.").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.key) { row in
                WebsiteEventRow(
                    model: model, shown: row,
                    replacement: WebsiteEvents.replacement(settings, baseTitle: row.event.baseTitle),
                    hide: { hide in
                        sync.update { events in
                            events = WebsiteEvents.setting(events, hidden: hide, baseTitle: row.event.baseTitle)
                        }
                    },
                    pickFromLibrary: { picking = row },
                    chooseFile: { chooseFile(for: row) },
                    useWebsite: { choose(nil, for: row) })
            }
            .disabled(!WebsiteEvents.isEnabled(settings, for: slideshow))
        } header: {
            header
        } footer: {
            Text(SettingsIndex.entry(id)?.caption ?? "")
        }
    }

    /// Shows `mediaID` instead of the website's picture for every event with
    /// this one's name; nil goes back to the website's.
    private func choose(_ mediaID: String?, for shown: WebsiteEvents.Shown) {
        sync.update { events in
            events = WebsiteEvents.setting(events, replacement: mediaID, baseTitle: shown.event.baseTitle)
        }
    }

    /// A picture from Finder: copied into Media › Announcements like the
    /// website's, then used for the event.
    private func chooseFile(for shown: WebsiteEvents.Shown) {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "A picture to show for \(shown.event.title) instead of the one on hopejc.org."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let placement = LibraryHome.Placement.drive(viewing: LibraryHome.Viewed(
                    kind: .media, area: .team, path: MediaLibraryCategory.announcements.folder ?? "Announcements"))
                if let id = await model.importFiles([url], placement: placement).first {
                    choose(id, for: shown)
                }
            }
        }
    }

    private var rows: [WebsiteEvents.Shown] {
        WebsiteEvents.desired(sync.events ?? [], now: Date(), options: WebsiteEvents.Options(settings), includingHidden: true)
    }

    private var studentRows: [WebsiteEvents.Shown] {
        WebsiteEvents.desired(
            sync.studentEvents ?? [], now: Date(), options: WebsiteEvents.Options(settings),
            includingHidden: true, calendar: StudentsHangTime.calendar)
    }

    private var lastSyncText: String {
        guard let date = sync.lastApplied ?? sync.lastFetched else { return "Not yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? "Last synced \(time)" : "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var footer: String {
        if let problem = sync.problem { return problem }
        let name = sync.slideshowID().flatMap { model?.libraryEntry($0)?.name } ?? "the pre-service slideshow"
        return "Added to \(name) and Students Hang Time after the slides made by hand, soonest first. Pictures are kept in Media › Announcements."
    }
}

private struct WebsiteEventRow: View {
    let model: AppModel?
    let shown: WebsiteEvents.Shown
    /// The picture chosen instead of the website's, if any.
    let replacement: String?
    let hide: @MainActor @Sendable (Bool) -> Void
    let pickFromLibrary: () -> Void
    let chooseFile: () -> Void
    let useWebsite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let replacement, let model, let item = model.media(replacement) {
                    WebsiteEventOwnPicture(model: model, item: item)
                } else {
                    WebsiteEventThumbnail(address: shown.imageURL)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(shown.hidden ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.event.title)
                    .lineLimit(1)
                    .foregroundStyle(shown.hidden ? .secondary : .primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu("Picture") {
                Button("Choose from Media Library…", action: pickFromLibrary)
                Button("Choose File…", action: chooseFile)
                Divider()
                Button("Use the Website's Picture", action: useWebsite)
                    .disabled(replacement == nil)
            }
            .fixedSize()
            .disabled(shown.hidden)
            Toggle("Don't show", isOn: Binding(get: { shown.hidden }, set: hide))
                .toggleStyle(.checkbox)
        }
    }

    private var subtitle: String {
        let when = WebsiteEventWords.row(shown)
        guard let replacement else { return when }
        let name = model?.media(replacement)?.name ?? "a picture that was deleted"
        return "\(when) \u{00B7} showing \(name)"
    }
}

/// A picture from the library chosen for an event, small.
private struct WebsiteEventOwnPicture: View {
    let model: AppModel
    let item: MediaItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fill)
            }
        }
        .task(id: item.fileHash) {
            guard let blobs = model.blobs else { return }
            image = await ThumbnailStore.shared.poster(for: item, blobs: blobs)
        }
    }
}

/// The event's picture, small: downscaled once and kept for the session, so
/// the list doesn't fetch and decode an 800 KB artwork every time it redraws.
private struct WebsiteEventThumbnail: View {
    let address: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fill)
            }
        }
        .task(id: address) { image = await WebsiteEventThumbnails.shared.image(for: address) }
    }
}

@MainActor
private final class WebsiteEventThumbnails {
    static let shared = WebsiteEventThumbnails()
    private let cache = NSCache<NSString, CGImage>()
    private var loading: [String: Task<CGImage?, Never>] = [:]

    init() { cache.countLimit = 60 }

    func image(for address: String) async -> CGImage? {
        if let cached = cache.object(forKey: address as NSString) { return cached }
        if let running = loading[address] { return await running.value }
        let task = Task<CGImage?, Never> {
            guard let url = URL(string: address),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await Task.detached(priority: .utility) { Self.downscaled(data) }.value
        }
        loading[address] = task
        let image = await task.value
        loading[address] = nil
        if let image { cache.setObject(image, forKey: address as NSString) }
        return image
    }

    nonisolated private static func downscaled(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
