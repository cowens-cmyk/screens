import Foundation
import MediaEngine
import PresenterCore
import SlideScene
import SwiftUI

/// Loads the day's plan into memory as soon as it's known, so nothing is
/// read from disk when a slide goes up: every presentation in the plan and
/// its themes, every picture decoded and ready to draw, every video opened
/// and its file read through (so the system keeps it in memory), and each
/// one's thumbnail. Before this a slide's words went up at once and its
/// picture a moment later, when the file had been read and decoded.
///
/// It runs when the app opens, and again a moment after the plan, its
/// presentations or the media change. Pictures are kept up to an eighth of
/// the Mac's memory and video files read through up to a quarter, in plan
/// order, so the start of the service is covered first on a small Mac; what
/// belongs to another plan is let go.
@MainActor
@Observable
final class PlanPreloader {
    static let shared = PlanPreloader()

    struct Status: Equatable {
        var done: Int
        var total: Int
    }

    /// How far along it is; nil when the plan is in memory (or there is none).
    private(set) var status: Status?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var controls: ServiceControls?
    @ObservationIgnored private var render: RenderContext?
    @ObservationIgnored private var playersGeneration = 0
    /// Where the plan was last known to be, kept while nothing is on the
    /// screens between items.
    @ObservationIgnored private var lastLiveIndex: Int?
    @ObservationIgnored private var lastPlanID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    func start(model: AppModel, render: RenderContext?, controls: ServiceControls) {
        guard self.model == nil, let render else { return }
        self.model = model
        self.render = render
        self.controls = controls
        model.whenLibraryReady { [weak self] in
            self?.schedule(after: .milliseconds(200))
            self?.watch()
            self?.watchPosition()
        }
    }

    // MARK: The next videos' players

    /// How many players wait at once: the item on screen and the next two
    /// seldom have more videos between them.
    private static let playersStandingBy = 6

    private func watchPosition() {
        guard let model, let controls else { return }
        withObservationTracking {
            _ = controls.liveContextID
            _ = controls.livePresentationID
            _ = model.currentServiceID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.readyUpcomingPlayers()
                self?.watchPosition()
            }
        }
    }

    /// One video the plan is about to play, and how.
    struct UpcomingVideo: Hashable {
        var mediaID: String
        var loop: Bool
    }

    /// The videos of the item on screen and the two after it, in order,
    /// each with the loop it will be played with (a slide's own choice, else
    /// the video's; the countdown always once).
    static func upcomingVideos(
        items: [ServiceItem], liveIndex: Int?, limit: Int,
        deck: (String) -> Presentation?, media: (String) -> MediaItem?
    ) -> [UpcomingVideo] {
        let from = max(liveIndex ?? 0, 0)
        var found: [UpcomingVideo] = []
        func add(_ id: String, loops: Bool?, once: Bool = false) {
            guard found.count < limit, let item = media(id), item.mediaKind == .video else { return }
            let video = UpcomingVideo(mediaID: id, loop: once ? false : loops ?? item.playsLooping)
            if !found.contains(video) { found.append(video) }
        }
        for item in items.dropFirst(from).prefix(3) {
            switch item.itemKind {
            case .media:
                add(item.refId, loops: nil, once: item.isCountdown == true)
            case .presentation:
                guard let deck = deck(item.refId) else { continue }
                for slide in deck.slides {
                    if let background = SlideSceneBuilder.effectiveBackground(
                        slide: slide, presentation: deck, arrangementId: item.arrangementId) {
                        add(background.mediaId, loops: background.loops)
                    }
                }
            default:
                break
            }
        }
        return found
    }

    /// Readies players for the videos about to be shown and lets go of the
    /// ones no longer coming up. Runs as the plan moves on and after each
    /// pass; a video already playing needs none.
    private func readyUpcomingPlayers() {
        guard let model, let render, let controls, let blobs = model.blobs else { return }
        let engine = render.media
        playersGeneration += 1
        let mine = playersGeneration
        guard let planID = model.currentServiceID, let plan = model.resident.services.value(planID) else {
            engine.releaseStandbyPlayers(keeping: [])
            return
        }
        if planID != lastPlanID {
            lastPlanID = planID
            lastLiveIndex = nil
        }
        let items = model.fireableItems(plan)
        if let live = controls.liveContextID, let index = items.firstIndex(where: { $0.id == live }) {
            lastLiveIndex = index
        }
        let playing = Set(engine.playingIDs)
        let wanted = Self.upcomingVideos(
            items: items, liveIndex: lastLiveIndex, limit: Self.playersStandingBy,
            deck: { model.presentation($0) }, media: { model.media($0) }
        ).compactMap { video -> (url: URL, loop: Bool, options: PlaybackOptions)? in
            guard !playing.contains(video.mediaID), let item = model.media(video.mediaID),
                  let url = blobs.url(forHash: item.fileHash)
            else { return nil }
            return (url, video.loop, PlaybackOptions(inPoint: item.inPoint, outPoint: item.outPoint, rate: item.playRate))
        }
        engine.releaseStandbyPlayers(keeping: Set(wanted.map(\.url)))
        Task { [weak self] in
            for video in wanted {
                guard self?.playersGeneration == mine else { return }
                await engine.standBy(playing: video.url, loop: video.loop, options: video.options)
            }
        }
    }

    private func watch() {
        guard let model else { return }
        withObservationTracking {
            _ = model.currentServiceID
            _ = model.fillVersion(of: .service)
            _ = model.kindVersions[.service]
            _ = model.kindVersions[.presentation]
            _ = model.kindVersions[.media]
            _ = model.kindVersions[.theme]
            _ = model.blobsVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule(after: .seconds(2))
                self?.watch()
            }
        }
    }

    /// A pass a moment from now; a later change starts the wait again, and
    /// a pass already running stops at its next file.
    private func schedule(after delay: Duration) {
        generation += 1
        let mine = generation
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.pass(mine)
        }
    }

    /// The media a plan uses, each once, in the order the plan reaches it.
    static func mediaIDs(
        items: [ServiceItem], decks: [String: Presentation], themes: (String) -> Theme?,
        stageLayouts: [ConfidenceLayout]
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ ids: some Sequence<String>) {
            for id in ids where !id.isEmpty && seen.insert(id).inserted { ordered.append(id) }
        }
        for layout in stageLayouts { add(MediaReferences.ids(inObjects: layout.objects).sorted()) }
        for item in items {
            switch item.itemKind {
            case .media:
                add([item.refId])
            case .presentation:
                guard let deck = decks[item.refId] else { continue }
                for id in themeIDs(of: deck) {
                    if let theme = themes(id) { add(MediaReferences.ids(in: theme).sorted()) }
                }
                add([deck.background?.mediaId, deck.backgroundFill?.mediaId].compactMap { $0 })
                for section in deck.sections ?? [] { add([section.background?.mediaId].compactMap { $0 }) }
                for slide in deck.slides { add(MediaReferences.ids(in: slide).sorted()) }
            default:
                break
            }
        }
        return ordered
    }

    /// Every theme a presentation draws with: its own, its slides', and the
    /// ones its livestream lower thirds come from.
    static func themeIDs(of deck: Presentation) -> [String] {
        var ids = [deck.themeId, deck.streamThemeId ?? ""]
        for slide in deck.slides {
            ids.append(slide.themeId ?? "")
            ids.append(slide.streamDesign?.themeId ?? "")
        }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func pass(_ mine: Int) async {
        guard let model, let render, let blobs = model.blobs else { return }
        let engine = render.media
        await model.resident.ready([.service, .media, .confidenceLayout])
        guard mine == generation else { return }
        guard let planID = model.currentServiceID, let plan = model.resident.services.value(planID) else {
            engine.releaseStandby(keeping: [])
            status = nil
            return
        }
        let started = Date()
        let items = model.runOfShow(plan)
        let deckIDs = items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }.map(\.refId)
        let decks = await model.presentationsFilled(deckIDs)
        var themeIDs = decks.values.flatMap(Self.themeIDs)
        if let series = plan.sermonThemeId, !series.isEmpty { themeIDs.append(series) }
        await model.themesFilled(themeIDs)
        guard mine == generation else { return }

        let ids = Self.mediaIDs(
            items: items, decks: decks, themes: { model.theme($0) },
            stageLayouts: model.resident.confidenceLayouts.values)
        let files = ids.compactMap { id -> (item: MediaItem, url: URL)? in
            guard let item = model.media(id), let url = blobs.url(forHash: item.fileHash) else { return nil }
            return (item, url)
        }
        // What another plan left behind goes first, to make room.
        engine.releaseStandby(keeping: Set(files.map(\.url)))

        let memory = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        var pictureRoom = memory / 8
        var videoRoom = memory / 4
        var pictures = 0, videos = 0, leftOut = 0
        status = files.isEmpty ? nil : Status(done: 0, total: files.count)
        for (index, file) in files.enumerated() {
            guard mine == generation else { return }
            let url = file.url
            switch file.item.mediaKind {
            case .image:
                let bytes = max(file.item.pixelWidth ?? 1920, 1) * max(file.item.pixelHeight ?? 1080, 1) * 4
                if engine.isStandingBy(url) {
                    pictureRoom -= bytes
                } else if bytes <= pictureRoom {
                    // What it really took, which is more than the guess for
                    // a picture whose size the library never recorded.
                    let taken = await Task.detached(priority: .utility) { (try? engine.standBy(still: url)) ?? 0 }.value
                    pictureRoom -= max(taken, bytes)
                    pictures += 1
                } else {
                    leftOut += 1
                }
            case .video:
                if !engine.isStandingBy(url) {
                    try? await engine.standBy(video: url)
                    // One that wouldn't open isn't read (it would be again
                    // on every pass), and a pass that has been overtaken
                    // stops here rather than read a whole file first.
                    guard engine.isStandingBy(url), mine == generation else { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 0, size <= videoRoom {
                        videoRoom -= size
                        await Task.detached(priority: .utility) { Self.readThrough(url) }.value
                    }
                    videos += 1
                }
            }
            _ = await ThumbnailStore.shared.poster(for: file.item, blobs: blobs, priority: .utility)
            if mine == generation { status = Status(done: index + 1, total: files.count) }
        }
        guard mine == generation else { return }
        status = nil
        readyUpcomingPlayers()
        if pictures + videos > 0 || leftOut > 0 {
            let seconds = Date().timeIntervalSince(started)
            DiagnosticsStore.shared.note(
                "plan.preload",
                detail: "\(plan.name): \(pictures) pictures, \(videos) videos, \(decks.count) presentations in "
                    + String(format: "%.1f s", seconds) + (leftOut > 0 ? ", \(leftOut) pictures left for when they're shown" : ""))
        }
    }

    /// Reads a file from end to end and throws the bytes away: the system
    /// keeps what it read in memory while there is room, so the video starts
    /// without waiting on the disk.
    nonisolated private static func readThrough(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {}
    }
}

/// "Loading the plan" with a bar, at the top of the Screens panel while the
/// plan is being read into memory.
struct PlanPreloadStatus: View {
    var body: some View {
        if let status = PlanPreloader.shared.status, status.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Loading the plan into memory")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 4)
                    Text("\(status.done) of \(status.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(status.done), total: Double(status.total))
                    .controlSize(.small)
            }
            .screenCard(HopeStyle.lightBlue)
            .help("Pictures and videos for today's plan are being read into memory, so each one goes up at once.")
        }
    }
}
