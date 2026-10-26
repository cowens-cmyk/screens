import AppKit
import Foundation
import Observation
import PresenterCore
import UniformTypeIdentifiers

/// Keeps the pre-service slideshow's event slides in step with hopejc.org:
/// each church event's artwork goes in a month before the event and comes
/// out when it starts (WebsiteEvents decides what shows; this fetches the
/// feed, brings the artwork into Media › Announcements and writes the
/// slides).
///
/// Plans and presentations sync church-wide, so only the Mac with Run on
/// this Mac on writes, like the countdowns and pre-service restarts. The
/// show Mac runs for days at a time, so the clock is watched with one-shot
/// timers set for the next change (an event's window opening, a slide's
/// time to come down, midnight), looked at again after sleep, a clock or
/// time zone change, and the feed is read every 30 minutes. With no
/// network, what's showing stays and only the slides whose time has passed
/// come out, worked out from the slides' own records.
@MainActor
@Observable
final class WebsiteEventSync {
    static let shared = WebsiteEventSync()

    private static let refreshSeconds: TimeInterval = 30 * 60
    /// How long to wait before trying again after the feed couldn't be read.
    private static let retryMinutes: [Double] = [1, 2, 5, 15, 30]
    /// A change held back because its slide is on the screens is tried again
    /// after about one slide's time.
    private static let liveRetrySeconds: TimeInterval = 15
    /// A wake or clock change fetches again only when the feed is older.
    private static let staleSeconds: TimeInterval = 5 * 60
    /// Synced artwork still used by a slide made by hand is checked again
    /// at most this often.
    private static let referenceCheckSeconds: TimeInterval = 24 * 3600

    /// The last feed read, nil until one has been.
    private(set) var events: [WebsiteEvent]?
    private(set) var lastFetched: Date?
    /// When the slides were last brought up to date on this Mac.
    private(set) var lastApplied: Date?
    /// One short line for Settings when something is wrong.
    private(set) var problem: String?
    private(set) var isWorking = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var controls: ServiceControls?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var lastModified: String?
    @ObservationIgnored private var boundaryTimer: Timer?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var refresher: NSBackgroundActivityScheduler?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var heldForLive = false
    @ObservationIgnored private var queued: Bool?
    /// Artwork brought in, by the address it came from. Kept to what the
    /// feed still names.
    @ObservationIgnored private var mediaByURL: [String: String] = [:]
    @ObservationIgnored private var referenceChecked: [String: Date] = [:]
    @ObservationIgnored private var lastNotes: [String: (detail: String, at: Date)] = [:]

    /// No disk cache: the feed is small and the artwork goes into the library.
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: Starting

    func start(model: AppModel, controls: ServiceControls) {
        guard self.model == nil else { return }
        self.model = model
        self.controls = controls

        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let recheck: @Sendable (Notification) -> Void = { note in
            let reason = note.name.rawValue
            Task { @MainActor in WebsiteEventSync.shared.clockMoved(reason) }
        }
        observers = [
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck)),
            (local, local.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: recheck)),
            (local, local.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: recheck)),
            (local, local.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: recheck)),
        ]

        // The 30-minute read rides the system's background scheduler, which
        // App Nap and a long uptime don't starve the way a run-loop timer
        // can be.
        let refresher = NSBackgroundActivityScheduler(identifier: "org.hopejc.screens.websiteEvents")
        refresher.repeats = true
        refresher.interval = Self.refreshSeconds
        refresher.tolerance = 120
        refresher.qualityOfService = .utility
        refresher.schedule { completion in
            completion(.finished)
            Task { @MainActor in
                let sync = WebsiteEventSync.shared
                if sync.writesHere { sync.run(fetch: true) }
            }
        }
        self.refresher = refresher

        model.whenLibraryReady {
            Task { @MainActor in
                let sync = WebsiteEventSync.shared
                sync.watchSettings()
                if sync.writesHere { sync.run(fetch: true) }
            }
        }
    }

    /// Whether this Mac writes the slides: the feature is on church-wide and
    /// this Mac runs the service.
    var writesHere: Bool {
        guard let model else { return false }
        return ServiceStation.runsService && WebsiteEvents.isEnabled(model.slideBuilding.websiteEvents)
    }

    var settings: WebsiteEventSettings? { model?.slideBuilding.websiteEvents }

    var options: WebsiteEvents.Options { WebsiteEvents.Options(settings) }

    func update(_ mutate: @escaping @Sendable (inout WebsiteEventSettings) -> Void) {
        model?.updateSlideBuilding { building in
            var events = building.websiteEvents ?? WebsiteEventSettings()
            mutate(&events)
            building.websiteEvents = events
        }
    }

    /// Settings changed here or on another Mac: the slides follow soon after.
    private func watchSettings() {
        guard let model else { return }
        withObservationTracking {
            _ = model.slideBuilding.websiteEvents
        } onChange: {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let sync = WebsiteEventSync.shared
                sync.watchSettings()
                // Turned off, the Mac that wrote the slides takes them out.
                if ServiceStation.runsService {
                    sync.run(fetch: sync.writesHere && sync.events == nil)
                }
            }
        }
    }

    private func clockMoved(_ reason: String) {
        guard writesHere else { return }
        note("websiteEvents.recheck", reason)
        run(fetch: lastFetched.map { Date().timeIntervalSince($0) > Self.staleSeconds } ?? true)
    }

    // MARK: Running

    /// Sync Now, and Settings opening: reads the feed on any Mac (so the
    /// list shows), and writes only where this Mac runs the service.
    func syncNow() {
        run(fetch: true)
    }

    /// One pass at a time; a call during a pass runs once more after it.
    private func run(fetch: Bool) {
        if isWorking {
            queued = (queued ?? false) || fetch
            return
        }
        isWorking = true
        Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.background], reason: "Updating hopejc.org events in the pre-service slides")
            if fetch { await fetchFeed() }
            if ServiceStation.runsService, model != nil {
                await apply(enabled: WebsiteEvents.isEnabled(settings))
            }
            ProcessInfo.processInfo.endActivity(activity)
            isWorking = false
            scheduleBoundary()
            if let again = queued {
                queued = nil
                run(fetch: again)
            }
        }
    }

    // MARK: The feed

    private func fetchFeed() async {
        var request = URLRequest(url: WebsiteEvents.feedURL(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if events != nil {
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 304, events != nil {
                fetched()
                return
            }
            guard status == 200 else { throw URLError(.badServerResponse) }
            let parsed = try WebsiteEvents.parseFeed(data)
            let headers = response as? HTTPURLResponse
            etag = headers?.value(forHTTPHeaderField: "ETag")
            lastModified = headers?.value(forHTTPHeaderField: "Last-Modified")
            events = parsed
            fetched()
            let wanted = Set(parsed.compactMap(\.image))
            mediaByURL = mediaByURL.filter { wanted.contains($0.key) }
        } catch {
            failures += 1
            let wait = Self.retryMinutes[min(failures, Self.retryMinutes.count) - 1]
            let at = Date().addingTimeInterval(wait * 60)
            problem = "Couldn't reach hopejc.org. Trying again at \(at.formatted(date: .omitted, time: .shortened))."
            note("websiteEvents.fetchFailed", "\(error.localizedDescription) (attempt \(failures))")
            scheduleRetry(after: wait * 60)
        }
    }

    private func fetched() {
        lastFetched = Date()
        if failures > 0 { note("websiteEvents.fetchRecovered", "after \(failures) attempts") }
        failures = 0
        problem = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: Writing the slides

    /// The pre-service slideshow every plan shows: the Service Day setup's,
    /// else the one named Pre-Service (found the same way everywhere).
    func slideshowID() -> String? {
        model?.preServiceSlideshowID()
    }

    /// Brings the slideshow's event slides up to date; turned off, takes
    /// them all out.
    private func apply(enabled: Bool) async {
        guard let model else { return }
        guard let deckID = slideshowID() else {
            problem = "No pre-service slideshow. Choose one in the Service Day setup."
            note("websiteEvents.noSlideshow", "")
            return
        }
        guard let deck = await model.presentationsFilled([deckID])[deckID] else { return }
        await model.resident.ready([.media])
        let now = Date()
        let live = controls?.livePresentationID == deckID ? controls?.liveSlideID : nil

        let plan: WebsiteEvents.SlidePlan
        let rewrite: @Sendable ([Slide]) -> WebsiteEvents.SlidePlan
        if !enabled {
            rewrite = { WebsiteEvents.plan(existing: $0, wanted: [], liveSlideID: live) }
        } else if let events {
            let shown = WebsiteEvents.desired(events, now: now, options: options)
            var wanted: [WebsiteEvents.Wanted] = []
            for item in shown {
                wanted.append(.init(shown: item, mediaID: await mediaID(for: item, in: deck.slides)))
            }
            let fixed = wanted
            rewrite = { WebsiteEvents.plan(existing: $0, wanted: fixed, liveSlideID: live) }
        } else {
            rewrite = { WebsiteEvents.expiredOnly(existing: $0, now: now, liveSlideID: live) }
        }
        plan = rewrite(deck.slides)
        heldForLive = plan.deferred

        if plan.changed {
            // Worked out again against the deck as the write finds it, so a
            // slide someone added a moment ago stays.
            let fresh = model.rewriteSlides(in: deckID) { presentation in
                presentation.slides = rewrite(presentation.slides).slides
            }
            if let fresh {
                controls?.presentationReplaced(fresh)
            } else {
                controls?.presentationEdited(deckID)
            }
            note("websiteEvents.applied",
                 "\(deck.name): +\(plan.added.count) ~\(plan.updated.count) -\(plan.removed.count)\(plan.moved ? " reordered" : "")")
        }
        lastApplied = now
        if problem?.hasPrefix("No pre-service") == true { problem = nil }
        // Artwork is let go on a pass that wrote nothing, once the slides
        // that used it are gone from the library.
        if !plan.changed {
            await removeUnusedArtwork(keeping: WebsiteEvents.mediaIDs(in: plan.slides), enabled: enabled)
        }
    }

    /// The media for an event's artwork: what its slide already shows when
    /// the picture hasn't changed, else artwork brought in before from the
    /// same address (on this Mac or another), else downloaded now.
    private func mediaID(for shown: WebsiteEvents.Shown, in slides: [Slide]) async -> String? {
        guard let model else { return nil }
        if let slide = slides.first(where: { $0.sourceEvent?.key == shown.key }),
           slide.sourceEvent?.imageUrl == shown.imageURL,
           let id = slide.background?.mediaId, model.media(id) != nil {
            return id
        }
        if let id = mediaByURL[shown.imageURL], model.media(id) != nil { return id }
        if let id = syncedArtwork().first(where: { $0.url == shown.imageURL })?.id {
            mediaByURL[shown.imageURL] = id
            return id
        }
        guard let id = await download(shown) else { return nil }
        mediaByURL[shown.imageURL] = id
        return id
    }

    /// Media this sync brought in, wherever it has been filed since.
    private func syncedArtwork() -> [(id: String, url: String)] {
        guard let model else { return [] }
        return model.entries(of: .media).compactMap { entry in
            guard let url = model.media(entry.id)?.sourceUrl else { return nil }
            return (entry.id, url)
        }
    }

    private func download(_ shown: WebsiteEvents.Shown) async -> String? {
        guard let model, let url = URL(string: shown.imageURL) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreensWebsiteEvents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            let (downloaded, response) = try await session.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: downloaded)
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var name = url.lastPathComponent.isEmpty ? "event" : url.lastPathComponent
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            if type?.conforms(to: .image) != true {
                let fromMIME = response.mimeType.flatMap { UTType(mimeType: $0) }?.preferredFilenameExtension ?? "jpg"
                name = (name as NSString).deletingPathExtension + "." + fromMIME
            }
            let file = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: downloaded, to: file)
            let placement = LibraryHome.Placement.drive(viewing: LibraryHome.Viewed(
                kind: .media, area: .team, path: MediaLibraryCategory.announcements.folder ?? "Announcements"))
            guard let id = await model.importFiles([file], placement: placement).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let title = shown.event.title
            let address = shown.imageURL
            model.updateMedia(id) { item in
                item.name = title
                item.sourceUrl = address
            }
            note("websiteEvents.downloaded", "\(title)")
            return id
        } catch {
            note("websiteEvents.downloadFailed", "\(shown.event.title): \(error.localizedDescription)")
            if problem == nil {
                problem = "Couldn't download the picture for \(shown.event.title). Trying again later."
            }
            return nil
        }
    }

    /// Artwork this sync brought in that no event wants any more and nothing
    /// in the library uses (someone may have put it on a slide of their own)
    /// is deleted, so the library doesn't fill with past events.
    private func removeUnusedArtwork(keeping used: Set<String>, enabled: Bool) async {
        guard let model else { return }
        let wantedURLs = enabled
            ? Set(WebsiteEvents.desired(events ?? [], now: Date(), options: options).map(\.imageURL)) : []
        let candidates = syncedArtwork().filter { !used.contains($0.id) && !wantedURLs.contains($0.url) }
        referenceChecked = referenceChecked.filter { id, _ in candidates.contains { $0.id == id } }
        // Without a feed, an event's artwork might only look unwanted.
        guard events != nil || !enabled else { return }
        for candidate in candidates {
            if let checked = referenceChecked[candidate.id], Date().timeIntervalSince(checked) < Self.referenceCheckSeconds {
                continue
            }
            if await model.mediaReferenceDocumentCount(of: [candidate.id]) > 0 {
                referenceChecked[candidate.id] = Date()
                continue
            }
            guard let entry = model.libraryEntry(candidate.id) else { continue }
            model.delete(entry)
            mediaByURL = mediaByURL.filter { $0.value != candidate.id }
            note("websiteEvents.removedArtwork", entry.name)
        }
    }

    // MARK: Timers

    /// One timer for the next moment something changes by the clock alone,
    /// replaced each pass. Capped so a long gap is still looked at.
    private func scheduleBoundary() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard writesHere, let model else { return }
        let now = Date()
        let tags = slideshowID().flatMap { model.presentation($0) }?.slides.compactMap(\.sourceEvent) ?? []
        var next = WebsiteEvents.nextBoundary(events ?? [], tags: tags, now: now, options: options)
        if heldForLive { next = min(next, now.addingTimeInterval(Self.liveRetrySeconds)) }
        // A second past the moment, so the pass sees it as arrived.
        let interval = min(max(next.timeIntervalSince(now) + 1, 1), 6 * 3600)
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in WebsiteEventSync.shared.boundaryArrived() }
        }
        timer.tolerance = min(20, max(1, interval * 0.02))
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    private func boundaryArrived() {
        boundaryTimer = nil
        guard writesHere else { return }
        run(fetch: false)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in
                let sync = WebsiteEventSync.shared
                sync.retryTimer = nil
                if sync.writesHere { sync.run(fetch: true) }
            }
        }
        timer.tolerance = min(30, seconds * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Diagnostics

    /// A note is written when it says something new, and a repeat at most
    /// once an hour, so a Mac left offline for a week doesn't fill the log.
    private func note(_ event: String, _ detail: String) {
        let now = Date()
        if let last = lastNotes[event], last.detail == detail, now.timeIntervalSince(last.at) < 3600 { return }
        lastNotes[event] = (detail, now)
        DiagnosticsStore.shared.note(event, detail: detail)
    }
}

/// Words for the website event slides, shared by Settings and the tiles.
enum WebsiteEventWords {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = WebsiteEvents.timeZone
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    /// "Sat, Oct 31, 5:00 PM", or "Sat, Oct 31" for a day.
    static func when(_ date: Date, withTime: Bool) -> String {
        formatter(withTime ? "EEE MMM d h:mm a" : "EEE MMM d").string(from: date)
    }

    /// "Sat, Oct 31 · until Oct 31, 5:00 PM".
    static func row(_ shown: WebsiteEvents.Shown) -> String {
        let timed = !shown.event.allDay && shown.event.startTime != nil
        return "\(when(shown.startsAt, withTime: timed)) \u{00B7} until \(untilWords(shown.removeAt))"
    }

    /// "Oct 29" when it comes down at the start of a day (all-day events),
    /// else "Oct 28 at 6:30 PM": "12:00 AM" reads like a mistake.
    static func untilWords(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WebsiteEvents.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
            ? formatter("MMM d").string(from: date)
            : formatter("MMM d h:mm a").string(from: date)
    }

    static func tileHelp(_ tag: WebsiteEventTag) -> String {
        let until = tag.removeAt.flatMap(WebsiteEvents.parseStamp)
            .map { " It comes down \(untilWords($0))." } ?? ""
        return "Added from hopejc.org for \(tag.title).\(until)"
    }
}
