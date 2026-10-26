import ImageIO
import PresenterCore
import SwiftUI

/// Settings › Integrations › Website: hopejc.org's events in the pre-service
/// slideshow. The choices are church-wide (any Mac can change them); the
/// Mac with Run on this Mac on does the adding and removing.
struct WebsiteEventsSettingsForm: View {
    let model: AppModel?
    @State private var sync = WebsiteEventSync.shared
    @AppStorage(ServiceStation.runsServiceKey) private var runsService = false

    private var settings: WebsiteEventSettings? { model?.slideBuilding.websiteEvents }

    var body: some View {
        Form {
            Section {
                SettingsToggle("website.events", isOn: Binding(
                    get: { WebsiteEvents.isEnabled(settings) },
                    set: { on in sync.update { $0.enabled = on } }))
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
            Section {
                if rows.isEmpty {
                    Text(sync.events == nil ? "Events haven't been read yet." : "No events in the next \(WebsiteEvents.Options(settings).windowDays) days.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.key) { row in
                    WebsiteEventRow(shown: row) { hide in
                        sync.update { events in
                            events = WebsiteEvents.setting(events, hidden: hide, baseTitle: row.event.baseTitle)
                        }
                    }
                }
            } header: {
                SettingsHeader(id: "website.list")
            } footer: {
                Text(SettingsIndex.entry("website.list")?.caption ?? "")
            }
        }
        .settingsForm()
        .onAppear {
            if sync.lastFetched.map({ Date().timeIntervalSince($0) > 60 }) ?? true { sync.syncNow() }
        }
    }

    private var rows: [WebsiteEvents.Shown] {
        WebsiteEvents.desired(sync.events ?? [], now: Date(), options: WebsiteEvents.Options(settings), includingHidden: true)
    }

    private var lastSyncText: String {
        guard let date = runsService ? sync.lastApplied : sync.lastFetched else { return "Not yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? "Last synced \(time)" : "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var footer: String {
        if let problem = sync.problem { return problem }
        if !runsService { return "Run on this Mac is off here, so another Mac adds and removes these slides." }
        let name = sync.slideshowID().flatMap { model?.libraryEntry($0)?.name } ?? "the pre-service slideshow"
        return "Added to \(name) after the slides made by hand, soonest first. Pictures are kept in Media › Announcements."
    }
}

private struct WebsiteEventRow: View {
    let shown: WebsiteEvents.Shown
    let hide: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            WebsiteEventThumbnail(address: shown.imageURL)
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(shown.hidden ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.event.title)
                    .lineLimit(1)
                    .foregroundStyle(shown.hidden ? .secondary : .primary)
                Text(WebsiteEventWords.row(shown))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Don't show", isOn: Binding(get: { shown.hidden }, set: hide))
                .toggleStyle(.checkbox)
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
