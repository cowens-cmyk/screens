import Foundation
import MediaEngine
import PresenterCore
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
    @ObservationIgnored private var render: RenderContext?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    func start(model: AppModel, render: RenderContext?) {
        guard self.model == nil, let render else { return }
        self.model = model
        self.render = render
        model.whenLibraryReady { [weak self] in
            self?.schedule(after: .milliseconds(200))
            self?.watch()
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
                    pictureRoom -= bytes
                    await Task.detached(priority: .utility) { _ = try? engine.standBy(still: url) }.value
                    pictures += 1
                } else {
                    leftOut += 1
                }
            case .video:
                if !engine.isStandingBy(url) {
                    try? await engine.standBy(video: url)
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
