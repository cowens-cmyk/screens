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
/// presentations or the media change. How much it keeps depends on the
/// Mac's memory (PlanPreloadPlan.budget): on 16 GB or less pictures up to an
/// eighth and files read through up to a quarter, in plan order, so the
/// start of the service is covered first; above that a quarter each, which
/// holds a whole plan. What belongs to another plan is let go, and so is
/// everything when macOS says it is short of memory, until it isn't.
///
/// Loading a plan (at launch, another plan opened, after memory came back)
/// shows in the main window's activity bar, and says when it's done and
/// what, if anything, didn't fit.
@MainActor
@Observable
final class PlanPreloader {
    static let shared = PlanPreloader()

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
    /// The plan the last finished pass loaded, so a pass for the same plan
    /// after an edit loads quietly and only a newly opened plan shows.
    @ObservationIgnored private var shownPlanID: String?
    /// How many pictures the last pass couldn't fit, so a quiet pass says
    /// so only when that changes.
    @ObservationIgnored private var lastLeftOut = 0
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    /// macOS asked for memory back; nothing is held until it says it has
    /// enough again.
    @ObservationIgnored private var memoryShort = false

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
        watchMemoryPressure()
    }

    // MARK: Memory pressure

    /// On macOS's warning the plan's pictures and video files are let go of
    /// (a picture on screen keeps its own copy, so nothing live changes) and
    /// the activity bar says so; when it says memory is back to normal the
    /// plan loads again.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated { self?.memoryPressureChanged(event) }
        }
        source.resume()
        memoryPressure = source
    }

    private func memoryPressureChanged(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.warning) || event.contains(.critical) {
            guard !memoryShort else { return }
            memoryShort = true
            generation += 1
            pending?.cancel()
            render?.media.releaseStandby(keeping: [])
            shownPlanID = nil
            model?.activity.notePlanReleased(at: Date())
            model?.scheduleActivityExpiry()
            DiagnosticsStore.shared.note("plan.preload", detail: "let go of for memory pressure")
        } else if event.contains(.normal), memoryShort {
            memoryShort = false
            schedule(after: .seconds(5))
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

    /// The videos of the item on screen and the two after it
    /// (PlanUpcomingVideos, in SlideScene, where it is tested).
    static func upcomingVideos(
        items: [ServiceItem], liveIndex: Int?, limit: Int,
        deck: (String) -> Presentation?, media: (String) -> MediaItem?
    ) -> [PlanUpcomingVideos.Video] {
        PlanUpcomingVideos.videos(items: items, liveIndex: liveIndex, limit: limit, deck: deck, media: media)
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

    private func pass(_ mine: Int) async {
        guard let model, let render, let blobs = model.blobs else { return }
        guard !memoryShort else { return }
        let engine = render.media
        await model.resident.ready([.service, .media, .audio, .confidenceLayout])
        guard mine == generation else { return }
        guard let planID = model.currentServiceID, let plan = model.resident.services.value(planID) else {
            engine.releaseStandby(keeping: [])
            model.activity.cancelPlanLoad()
            shownPlanID = nil
            return
        }
        // A plan opened (or the first since launch, or since memory came
        // back) shows in the activity bar; a pass after an edit to the same
        // plan loads quietly.
        let shows = planID != shownPlanID
        let started = Date()
        let items = model.runOfShow(plan)
        let deckIDs = items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }.map(\.refId)
        let decks = await model.presentationsFilled(deckIDs)
        let rules = model.slideBuilding.presentationTypeRules
        // The themes the livestream can be sent to whatever the item: the
        // series, the plan's own, and each type's lower-third design.
        var streamThemes = [plan.sermonThemeId, model.slideBuilding.sermonThemeId].compactMap { $0 }
        for deck in decks.values {
            if case .design(let themeID, _) = model.slideBuilding
                .screens(forType: PresentationTypes.screensType(of: deck)).livestream {
                streamThemes.append(themeID)
            }
        }
        streamThemes = streamThemes.filter { !$0.isEmpty }
        // Twice: a theme read in can name the stream's themes.
        await model.themesFilled(decks.values.flatMap { PlanPreloadPlan.themeIDs(of: $0) } + streamThemes)
        let themes: (String) -> Theme? = { model.theme($0) }
        await model.themesFilled(
            decks.values.flatMap { PlanPreloadPlan.themeIDs(of: $0, themes: themes) }
                + streamThemes.flatMap { themes($0)?.streamThemeReferences ?? [] })
        guard mine == generation else { return }

        let ids = PlanPreloadPlan.mediaIDs(
            items: items, decks: decks, themes: themes,
            stageLayouts: model.resident.confidenceLayouts.values,
            streamThemeIDs: streamThemes,
            typeActions: { PresentationTypes.actions(for: $0, rules: rules) })
        let files = ids.compactMap { id -> (item: MediaItem, url: URL)? in
            guard let item = model.media(id), let url = blobs.url(forHash: item.fileHash) else { return nil }
            return (item, url)
        }
        // Audio plays from its file, opened when it's started: read through
        // like a video's, so that open doesn't wait on the disk.
        let sounds = PlanPreloadPlan.audioIDs(items: items).compactMap { id -> URL? in
            model.audio(id).flatMap { blobs.url(forHash: $0.fileHash) }
        }
        // What another plan left behind goes first, to make room.
        engine.releaseStandby(keeping: Set(files.map(\.url)))

        let budget = PlanPreloadPlan.budget(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        var pictureRoom = budget.pictures
        var fileRoom = budget.files
        var pictures = 0, videos = 0, leftOut = 0
        let total = files.count + sounds.count
        if shows {
            if total > 0 { model.activity.beginPlanLoad(total: total) } else { model.activity.cancelPlanLoad() }
        }
        func progressed(_ done: Int) {
            if shows, mine == generation { model.activity.notePlanLoad(done: done, total: total) }
        }
        for (index, file) in files.enumerated() {
            guard mine == generation else { return }
            let url = file.url
            switch file.item.mediaKind {
            case .image:
                let bytes = PlanPreloadPlan.pictureBytes(width: file.item.pixelWidth, height: file.item.pixelHeight)
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
                    if size > 0, size <= fileRoom {
                        fileRoom -= size
                        await Task.detached(priority: .utility) { Self.readThrough(url) }.value
                    }
                    videos += 1
                }
            }
            _ = await ThumbnailStore.shared.poster(for: file.item, blobs: blobs, priority: .utility)
            progressed(index + 1)
        }
        for (index, url) in sounds.enumerated() {
            guard mine == generation else { return }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0, size <= fileRoom {
                fileRoom -= size
                await Task.detached(priority: .utility) { Self.readThrough(url) }.value
            }
            progressed(files.count + index + 1)
        }
        guard mine == generation else { return }
        if (shows && total > 0) || (leftOut > 0 && leftOut != lastLeftOut) {
            model.activity.endPlanLoad(files: total, leftOut: leftOut, at: Date())
            model.scheduleActivityExpiry()
        }
        lastLeftOut = leftOut
        shownPlanID = planID
        readyUpcomingPlayers()
        if pictures + videos > 0 || leftOut > 0 {
            let seconds = Date().timeIntervalSince(started)
            DiagnosticsStore.shared.note(
                "plan.preload",
                detail: "\(plan.name): \(pictures) pictures, \(videos) videos, \(sounds.count) audio, \(decks.count) presentations in "
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
