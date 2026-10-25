import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct ServiceContinuousView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let serviceID: String

    let focusItemID: String?

    @Binding var focusScroll: PresentFocusScroll

    /// The item the page has come to by itself (the operator's scroll, or
    /// following the live slide), for the plan list to highlight.
    var onShowItem: ((String) -> Void)? = nil

    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback

    @Environment(\.runOnly) private var runOnly
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var deleteRequests = 0

    @State private var clipboardRequests = SlideClipboardRequests()

    @State private var mediaMenuState = MediaCueMenuState()
    @State private var playlistDropTarget: PlaylistDropTarget?

    @State private var viewportHeight: CGFloat = 0

    @State private var headerHeights: [String: CGFloat] = [:]

    /// The page's width, for the media rows' automatic slides across (the
    /// slide grids measure their own).
    @State private var pageWidth: CGFloat = 0

    /// Add Slide for a presentation with no slides: there is no grid to
    /// answer New Slide, so the page asks.
    @State private var emptyDeckNewSlide: EmptyDeckNewSlide?

    /// From Media Library… for a presentation with no slides.
    @State private var emptyDeckMedia: MediaSlideTarget?

    /// The livestream question for slides just made from media here.
    @State private var livestreamPrompt: LivestreamPromptRequest?

    /// The page's side margin; the slide grids reach their marquee over it.
    static let pageMargin: CGFloat = 12

    /// The items the operator picked in the plan list, for LiveSlideFollow.
    @State private var picks = PresentPicks()

    static let scrollSpace = "presentScroll"

    static let contentSpace = "presentContent"

    private struct FirePosition {
        let itemID: String
        let presentation: Presentation
        let arrangementId: String?
        let occurrence: Int
        let slide: Slide
    }

    var body: some View {
        let _ = BodyMeter.tick(.serviceContinuous)
        let _ = model.listVersion
        if let service = try? model.service(serviceID) {
            let positions = firePositions(service)

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView {

                            VStack(alignment: .leading, spacing: 0) {

                                let rows = presentRows(service)

                                let _ = PresentCardFrames.shared.show(rows)
                                ForEach(rows, id: \.presentRowIdentity) { item in
                                    itemSection(item, proxy: proxy)

                                        .background {
                                            GeometryReader { geo in
                                                let _ = PresentCardFrames.shared.note(
                                                    item.id, geo.frame(in: .named(Self.scrollSpace)))
                                                let _ = PresentCardFrames.shared.noteDoc(
                                                    item.id, geo.frame(in: .named(Self.contentSpace)))
                                                Color.clear
                                            }
                                        }
                                }
                            }

                            .padding(.horizontal, Self.pageMargin)
                            .padding(.bottom, 12)

                            .background(alignment: .topLeading) {
                                PresentScrollWatch().frame(width: 1, height: 1)
                            }
                            .coordinateSpace(name: Self.contentSpace)
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .inputRegion("present")
                        .onAppear {
                            viewportHeight = viewport.size.height
                            PresentCardFrames.shared.viewportHeight = viewport.size.height
                            pageWidth = viewport.size.width
                        }
                        .onChange(of: viewport.size.height) { _, height in
                            viewportHeight = height
                            PresentCardFrames.shared.viewportHeight = height
                        }

                        .onChange(of: viewport.size.width) { _, width in
                            PresentCardFrames.shared.keepPlace(because: "width")
                            pageWidth = width
                        }
                        .onChange(of: slidesAcross) { _, _ in
                            PresentCardFrames.shared.keepPlace(because: "slides across")
                        }
                    }
                    .onChange(of: focusItemID) { _, id in
                        // The page moving the selection itself (following the
                        // live slide, the operator's scroll) marks the item
                        // first; anything else is the operator's pick.
                        if focusScroll.honoredItemID != id { picks.pick(id) }
                        scrollToFocus(id, reason: "selection", proxy: proxy, service: service)
                        pointNewSlide(at: id)
                    }

                    .onChange(of: focusScroll.reselects) { _, _ in
                        picks.pick(focusItemID)
                        scrollToFocus(focusItemID, reason: "reselect", proxy: proxy, service: service)
                        pointNewSlide(at: focusItemID)
                    }
                    .onAppear {

                        scrollToFocus(focusItemID, reason: "appear", proxy: proxy, service: service)
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onPresentFireKeys {
                    fireStep($0, positions)
                    controls?.noteKeyboardFire()
                }

                .background(KeyboardFireFollow(controls: controls) { revealLive(service) })
                // Everything else that puts a slide up: the remote, Anthem,
                // a slide's own timing, a click.
                .background(LiveSlideFollow(controls: controls, picks: picks) { followLive($0, service) })

                .onDeleteCommand { deleteRequests += 1 }
                .onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }
            }
            .onAppear {
                focused = true
                PresentCardFrames.shared.onOperatorScroll = onShowItem
            }

            .onChange(of: model.listVersion) {
                controls?.refreshNextSlide()
            }
            .onChange(of: NewSlideRouter.shared.requests) { _, _ in newSlideForEmptyDeck(service) }
            .sheet(item: $emptyDeckNewSlide) { target in
                NewSlideSheet(appModel: model, render: render, deckThemeId: target.themeId, startsWithThemes: true) { choice in
                    model.insertSlide(
                        target.presentationID,
                        slide: choice.slide(sectionId: nil, deckThemeId: target.themeId),
                        afterSlideID: target.afterSlideID)
                }
            }
            .sheet(item: $emptyDeckMedia) { target in
                MediaSlidePickerSheet(model: model) { mediaIDs in
                    addMediaSlides(mediaIDs, to: target.presentationID, after: target.afterSlideID)
                }
            }
            .sheet(item: $livestreamPrompt) { LivestreamPromptSheet(model: model, request: $0) }
            .mediaCueSheets(model: model, state: mediaMenuState)
            // The page sits on the window's dark backdrop and paints no
            // background of its own, so it reads as dark whatever the Mac's
            // appearance.
            .environment(\.colorScheme, .dark)
        } else {
            ContentUnavailableView(
                "No Service", systemImage: "calendar",
                description: Text("Choose a service to present.")
            )
            .environment(\.colorScheme, .dark)
        }
    }

    /// Space under each item before the next one's hairline.
    private static let itemGap: CGFloat = 28

    private static var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
    }

    @ViewBuilder
    private func itemSection(_ item: ServiceItem, proxy: ScrollViewProxy) -> some View {
        switch item.itemKind {
        case .header:
            if item.isHidden {
                Rectangle()
                    .fill((headerTint(item) ?? Color(nsColor: .separatorColor)).opacity(0.45))
                    .frame(height: 1)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .id(item.id)
            } else {
                // A solid band in the header's color, as in the plan list
                // and ProPresenter's playlist.
                Text(item.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GroupColor.text(onHex: item.colorHex))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(
                        headerTint(item) ?? HopeStyle.navy.opacity(0.85),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .id(item.id)
            }
        case .info:

            Section {
                EmptyView()
            } header: {
                CardRefresh(model: model) { unlinkedCard(item) }
            }
        case .presentation:
            stickySection(item) {
                CardRefresh(model: model) { presentationBodyFresh(item) }
            } header: {
                CardRefresh(model: model) { presentationHeaderFresh(item, proxy: proxy) }
            }
        case .media:
            stickySection(item) {
                CardRefresh(model: model) { mediaCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item) {
                        if let media = model.media(item.refId) {
                            mediaContext(media)
                        }
                    } leading: {
                        if item.isCountdown == true, !runOnly {
                            CountdownVideoMenu(model: model, planID: serviceID, item: item)
                                .fixedSize()
                        }
                    }
                    .contextMenu { mediaQuickMenu(item) }

                    .id("mediaHeaderMenu|\(item.id)|\(model.media(item.refId) == nil)")
                }
            }
        case .audio:
            stickySection(item) {
                CardRefresh(model: model) { audioCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item) {
                        let isLive = controls?.state.liveAudio
                            .contains { $0.audioItemId == item.refId } ?? false
                        playStopChip(
                            isLive: isLive,
                            help: isLive ? "Stop" : "Play"
                        ) {
                            if isLive {
                                controls?.stopAudio(audioItemID: item.refId)
                            } else if let audioItem = model.audio(item.refId) {
                                controls?.fire(audioItem: audioItem)
                            }
                        }
                    }
                }
            }
        case .playlist:
            stickySection(item) {
                CardRefresh(model: model) { playlistCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item) {
                        if let playlist = try? model.playlist(item.refId) {
                            let isLive = controls?.state.liveAudio
                                .contains { $0.playlistId == playlist.id } ?? false
                            Text("\(playlist.entries.count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            playStopChip(
                                isLive: isLive,
                                help: isLive ? "Stop the playlist" : "Play the playlist"
                            ) {
                                if isLive {
                                    controls?.stopAudio(playlistID: playlist.id)
                                } else {
                                    controls?.fire(playlist: playlist)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func playStopChip(
        isLive: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isLive ? "stop.fill" : "play.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(isLive ? "Stop" : "Play")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isLive ? Color.green : .secondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(help)
    }

    @ViewBuilder
    private func playlistCardBody(_ item: ServiceItem) -> some View {
        if let playlist = try? model.playlist(item.refId) {
            let isLive = controls?.state.liveAudio
                .contains { $0.playlistId == playlist.id } ?? false

            VStack(spacing: 2) {

                if let player = controls?.audio.player(forPlaylist: playlist.id) {
                    AudioTransportControls(model: model, player: player) { EmptyView() }
                    AudioScrubBar(player: player, showsTimes: true)
                        .padding(.bottom, 6)
                }
                ForEach(playlist.entries, id: \.id) { track in
                    playlistTrackRow(track, in: playlist, isLive: isLive)
                }
                if !runOnly {
                    cardAddTrackRow(playlist)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {

                if playlistDropTarget?.playlistID == playlist.id,
                   playlistDropTarget?.beforeEntryID == nil {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(height: 2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                !runOnly && dropOnPlaylist(playlist, payloads: payloads, before: nil)
            } isTargeted: { targeted in
                playlistDropTarget = targeted
                    ? PlaylistDropTarget(playlistID: playlist.id, beforeEntryID: nil)
                    : (playlistDropTarget?.beforeEntryID == nil ? nil : playlistDropTarget)
            }
            .padding(.bottom, Self.itemGap)
        }
    }

    struct PlaylistDropTarget: Equatable {
        let playlistID: String
        let beforeEntryID: String?
    }

    private func dropOnPlaylist(
        _ playlist: Playlist, payloads: [String], before entryID: String?
    ) -> Bool {
        playlistDropTarget = nil
        let changed = model.handlePlaylistDrop(
            playlist.id, payloads: payloads, beforeEntryID: entryID
        )
        if changed { controls?.audio.playlistDocumentChanged() }
        return changed
    }

    private func playlistTrackRow(
        _ track: PlaylistEntry, in playlist: Playlist, isLive: Bool
    ) -> some View {
        let isCurrent = controls?.audio.player(forPlaylist: playlist.id)?.currentEntryID == track.id
        return Button {
            controls?.fire(playlist: playlist, startAt: track.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "waveform" : "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 14)
                Text(model.entry(track.refId)?.name ?? track.refId)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent, let player = controls?.audio.player(forPlaylist: playlist.id),
                   player.duration > 0 {
                    AudioTimecode(player: player)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let seconds = playlistTrackSeconds(track) {
                    Text(timecode(seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isCurrent ? Color.green.opacity(0.10) : Color.clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .help("Play the playlist starting here")
        .contextMenu {
            if !runOnly {
                Button("Remove from Playlist", role: .destructive) {
                    model.removePlaylistEntry(playlist.id, entryID: track.id)
                    controls?.audio.playlistDocumentChanged()
                }
            }
        }
        .padding(.vertical, 1)

        .draggablePayload(runOnly ? nil : "pltrk::\(playlist.id)::\(track.id)")
        .dropDestination(for: String.self) { payloads, _ in
            guard !runOnly else { return false }
            return dropOnPlaylist(playlist, payloads: payloads, before: track.id)
        } isTargeted: { targeted in
            playlistDropTarget = targeted
                ? PlaylistDropTarget(playlistID: playlist.id, beforeEntryID: track.id)
                : (playlistDropTarget?.beforeEntryID == track.id ? nil : playlistDropTarget)
        }
        .overlay(alignment: .top) {
            if playlistDropTarget?.playlistID == playlist.id,
               playlistDropTarget?.beforeEntryID == track.id {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func cardAddTrackRow(_ playlist: Playlist) -> some View {

        let candidates = model.entries(in: (playlist.playlistKind ?? .audio) == .media ? .media : .audio)
        return Menu {
            ForEach(candidates, id: \.id) { candidate in
                Button(candidate.name) {
                    model.addToPlaylist(playlist.id, itemID: candidate.id)
                    controls?.audio.playlistDocumentChanged()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 14)
                Text("Add Track")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func playlistTrackSeconds(_ track: PlaylistEntry) -> Double? {
        switch track.refKind {
        case .audio: model.audio(track.refId)?.durationSeconds
        case .media: model.media(track.refId)?.durationSeconds
        }
    }

    private func audioCardBody(_ item: ServiceItem) -> some View {
        let isLive = controls?.state.liveAudio
            .contains { $0.audioItemId == item.refId } ?? false
        let player = controls?.audio.player(forAudioItem: item.refId)
        return HStack(spacing: 8) {
            Image(systemName: isLive ? "waveform" : "music.note")
                .font(.system(size: 9))
                .foregroundStyle(isLive ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 14)
            Text(item.name)
                .font(.caption)
                .foregroundStyle(isLive ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let player, player.duration > 0 {

                AudioScrubBar(player: player, showsTimes: true)
                    .frame(maxWidth: 320)
            } else if let seconds = model.audio(item.refId)?.durationSeconds {
                Text(timecode(seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isLive ? Color.green.opacity(0.10) : Color.clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .padding(.top, 4)
        .padding(.bottom, Self.itemGap)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func presentationBodyFresh(_ item: ServiceItem) -> some View {

        if let presentation = model.presentation(item.refId) {
            let slides = model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            if presentation.slides.isEmpty {
                // No slides at all: a slide-sized space to drop some into.
                emptyDeckBody(item, presentation)
            } else if slides.isEmpty {
                Text("This arrangement has no slides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.bottom, Self.itemGap)
            } else {
                presentationCardBody(item, presentation, slides)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    @ViewBuilder
    private func presentationHeaderFresh(_ item: ServiceItem, proxy: ScrollViewProxy) -> some View {

        if let presentation = model.presentation(item.refId) {
            let slides = model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            cardHeader(item) {
                // One count for the whole item instead of a triangle on every tile.
                PresentationIssuesBadge(
                    model: model, presentation: presentation,
                    arrangementId: item.arrangementId, slides: slides)
                CardSlidePosition(controls: controls, itemID: item.id, slideCount: slides.count)
            } leading: {

                if presentation.sections?.isEmpty == false {
                    if runOnly {
                        if let name = activeArrangementName(item, presentation) {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ArrangementPicker(
                            model: model, presentation: presentation,
                            selection: Binding(
                                get: { item.arrangementId },
                                set: { arrangementID in
                                    model.setServiceItemArrangement(
                                        serviceID, itemID: item.id, arrangementID: arrangementID
                                    )
                                }
                            )
                        )
                    }
                }
                AnthemMismatchBadge(model: model, serviceID: serviceID, itemID: item.id, labeled: true)
                SongKeyChip(model: model, controls: controls, presentation: presentation)
                SlideShowChip(model: model, controls: controls, presentation: presentation)
                LyricFollowChip(controls: controls, presentation: presentation)
            } accessory: {

                if showsSectionChips(item, presentation) {
                    ArrangementStrip(
                        model: model, presentation: presentation,
                        selection: Binding(
                            get: { item.arrangementId },
                            set: { arrangementID in
                                model.setServiceItemArrangement(
                                    serviceID, itemID: item.id, arrangementID: arrangementID
                                )
                            }
                        ),
                        showsPicker: false,
                        onJump: { pill in
                            jumpToBlock(item, presentation, slides, pill: pill, proxy: proxy)
                        }
                    )
                }
            }

            .contextMenu {
                if !runOnly { presentationMenu(item, presentation) }
            }
        } else {

            cardHeader(item) { EmptyView() }
        }
    }

    /// The section chips help when there's somewhere to jump: an
    /// arrangement, or more than one section in the plain order.
    private func showsSectionChips(_ item: ServiceItem, _ presentation: Presentation) -> Bool {
        guard presentation.sections?.isEmpty == false else { return false }
        if activeArrangementName(item, presentation) != nil { return true }
        return SlideSceneBuilder.arrangementBlockStarts(
            for: presentation, arrangementId: item.arrangementId
        ).count > 1
    }

    @ViewBuilder
    private func presentationMenu(_ item: ServiceItem, _ presentation: Presentation) -> some View {
        Button("Add Slide\u{2026}") { requestNewSlide(item) }
        arrangementMenu(item, presentation)
    }

    /// Present has no Add Slide row; this goes through New Slide's router,
    /// so the item's grid (or, with no slides yet, the page) answers.
    private func requestNewSlide(_ item: ServiceItem) {
        NewSlideRouter.shared.route = NewSlideRoute(contextID: item.id)
        NewSlideRouter.shared.request()
    }

    private func newSlideForEmptyDeck(_ service: Service) {
        guard !runOnly, let id = NewSlideRouter.shared.route.contextID,
              let item = service.items.first(where: { $0.id == id && $0.itemKind == .presentation }),
              let presentation = model.presentation(item.refId),
              model.arrangedSlides(presentation, arrangementId: item.arrangementId).isEmpty
        else { return }
        emptyDeckNewSlide = EmptyDeckNewSlide(
            presentationID: presentation.id, themeId: presentation.themeId,
            afterSlideID: presentation.slides.last?.id)
    }

    /// An empty presentation's body: one tile-sized drop area where its
    /// first slide would be, sized like the slide tiles around it.
    private func emptyDeckBody(_ item: ServiceItem, _ presentation: Presentation) -> some View {
        let across = SlidesAcross.resolved(
            slidesAcross, width: pageWidth - Self.pageMargin * 2, spacing: SlideGridMetrics.spacing)
        let row = SlidesAcross.rows(count: 1, across: across)[0]
        let presentationID = presentation.id
        return HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
            VStack(spacing: SlideGridMetrics.labelGap) {
                EmptySlidesDropArea(
                    aspect: SlideGridMetrics.tileAspect(for: presentation),
                    locked: runOnly,
                    choices: AddSlideChoices(
                        fromTheme: {
                            emptyDeckNewSlide = EmptyDeckNewSlide(
                                presentationID: presentationID, themeId: presentation.themeId, afterSlideID: nil)
                        },
                        fromMedia: {
                            emptyDeckMedia = MediaSlideTarget(presentationID: presentationID, afterSlideID: nil)
                        },
                        blank: {
                            model.insertSlide(
                                presentationID,
                                slide: NewSlideChoice.blank.slide(sectionId: nil, deckThemeId: presentation.themeId),
                                afterSlideID: nil)
                        }
                    ),
                    dropText: { dropOnEmptyDeck($0, presentationID: presentationID) },
                    dropFiles: { urls in
                        Task { @MainActor in
                            let imported = await model.importFiles(urls)
                            addMediaSlides(imported, to: presentationID)
                        }
                    },
                    breadcrumb: "present.emptyDrop",
                    roundedCorners: roundedCorners
                )
                // The label strip under a slide tile, so the space is a tile's size.
                Color.clear.frame(height: SlideGridMetrics.labelHeight)
            }
            .frame(maxWidth: .infinity)
            ForEach(0 ..< row.fillers, id: \.self) { _ in
                Color.clear.frame(height: 0).frame(maxWidth: .infinity)
            }
        }
        .background {
            // No grid: tell the page so an earlier grid's rows don't stand in
            // for this item when it keeps its place.
            GeometryReader { proxy in
                let _ = PresentCardFrames.shared.noteGrid(PresentLanding.Grid(
                    id: item.id, top: proxy.frame(in: .named(Self.scrollSpace)).minY,
                    rowPitch: 0, across: across, count: 0))
                let _ = PresentCardFrames.shared.noteDocGrid(PresentLanding.Grid(
                    id: item.id, top: proxy.frame(in: .named(Self.contentSpace)).minY,
                    rowPitch: 0, across: across, count: 0))
                Color.clear
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Self.itemGap)
    }

    /// A slide dragged from another presentation is copied in; a picture or
    /// video from the Media library becomes a slide with it as the background.
    private func dropOnEmptyDeck(_ payload: String, presentationID: String) -> Bool {
        guard !runOnly else { return false }
        if let dragged = SlideBulkEdit.draggedSlide(in: payload) {
            return dragged.presentationID != presentationID
                && model.presentationExists(dragged.presentationID)
                && model.copySlide(dragged.slideID, from: dragged.presentationID, to: presentationID)
        }
        guard !payload.contains("::"), model.media(payload) != nil else { return false }
        return addMediaSlides([payload], to: presentationID)
    }

    @discardableResult
    private func addMediaSlides(_ mediaIDs: [String], to presentationID: String, after afterSlideID: String? = nil) -> Bool {
        guard !runOnly else { return false }
        let added = MediaSlides.make(mediaIDs, model: model)
        guard !added.isEmpty else { return false }
        model.insertSlides(presentationID, slides: added, afterSlideID: afterSlideID)
        let actionRouter = controls?.actionRouter
        let asked = LivestreamPromptRequest.make(model, presentationID: presentationID, added: added) { design, ids in
            let chosen = Set(ids)
            model.updateSlides(presentationID: presentationID, undoLabel: "Livestream") { deck in
                for index in deck.slides.indices where chosen.contains(deck.slides[index].id) {
                    deck.slides[index].streamDesign = design
                }
            }
            actionRouter?.noteStreamDesign(design, forSlides: chosen)
        }
        if let asked { livestreamPrompt = livestreamPrompt.map { $0.adding(asked) } ?? asked }
        return true
    }

    private func cardHeader(
        _ item: ServiceItem,
        @ViewBuilder detail: () -> some View,
        @ViewBuilder leading: () -> some View = { EmptyView() },
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        // No card: a hairline above, the name, the item's controls, and the
        // section chips; the page's own background shows through.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The same badge as the item's row in the plan list.
                ItemKindBadge(kind: HopeStyle.kind(
                    of: item, presentation: item.itemKind == .presentation ? model.presentation(item.refId) : nil))
                Text(displayName(item))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                leading()
                Spacer(minLength: 8)
                detail()
            }

            accessory()
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Self.hairline }
        .id(item.id)
    }

    private func activeArrangementName(
        _ item: ServiceItem, _ presentation: Presentation
    ) -> String? {
        guard let id = item.arrangementId, !id.isEmpty else { return nil }
        return presentation.arrangements?.first { $0.id == id }?.name
    }

    private func jumpToBlock(
        _ item: ServiceItem, _ presentation: Presentation, _ slides: [Slide],
        pill: Int, proxy: ScrollViewProxy
    ) {
        let starts = SlideSceneBuilder.arrangementBlockStarts(
            for: presentation, arrangementId: item.arrangementId
        )
        guard starts.indices.contains(pill), starts[pill] < slides.count else { return }
        let headerFraction = viewportHeight > 0
            ? min(((headerHeights[item.id] ?? 44) + 12) / viewportHeight, 0.4) : 0
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(
                SlideGridBody.tileAnchor(contextID: item.id, index: starts[pill]),
                anchor: UnitPoint(x: 0, y: headerFraction)
            )
        }
    }

    @ViewBuilder
    private func arrangementMenu(_ item: ServiceItem, _ presentation: Presentation) -> some View {
        if let arrangements = presentation.arrangements, !arrangements.isEmpty {
            Menu("Arrangement") {
                Toggle("Default", isOn: Binding(
                    get: { item.arrangementId?.isEmpty ?? true },
                    set: { _ in
                        model.setServiceItemArrangement(
                            serviceID, itemID: item.id, arrangementID: nil
                        )
                    }
                ))
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(arrangement.name, isOn: Binding(
                        get: { item.arrangementId == arrangement.id },
                        set: { _ in
                            model.setServiceItemArrangement(
                                serviceID, itemID: item.id, arrangementID: arrangement.id
                            )
                        }
                    ))
                }
            }
        }
    }

    private func pointNewSlide(at itemID: String?) {
        if let itemID {
            NewSlideRouter.shared.route = NewSlideRoute(contextID: itemID)
        }
    }

    private func presentationCardBody(
        _ item: ServiceItem, _ presentation: Presentation, _ slides: [Slide]
    ) -> some View {
        let theme = model.theme(presentation.themeId)

        return VStack(alignment: .leading, spacing: 10) {
            SlideGridBody(
                    model: model, render: render, controls: controls,
                    presentation: presentation, theme: theme,
                    slides: slides,
                    arrangementId: item.arrangementId,
                    contextID: item.id,
                    roundedCorners: roundedCorners,
                    hideScopedBackgrounds: hideScopedBackgrounds,
                    legibleText: legibleText,
                    chosenAcross: slidesAcross,
                    deleteRequests: deleteRequests,
                    clipboardRequests: clipboardRequests,
                    pastesAtEnd: focusItemID == item.id,
                    newSlideContexts: ((try? model.service(serviceID))?.items ?? [])
                        .filter { $0.itemKind == .presentation }.map(\.id),
                    buildsRowsNearView: true,
                    marqueeMargin: 12
                )
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Self.itemGap)
    }

    @ViewBuilder
    private func mediaQuickMenu(_ item: ServiceItem) -> some View {

        Group {
            if !runOnly {
                MediaCueMenuItems(
                    model: model, actionRouter: controls?.actionRouter,
                    mediaID: item.refId, state: mediaMenuState,
                    fallbackName: item.name
                )
            }
        }
    }

    private func mediaCardBody(_ item: ServiceItem) -> some View {
        let media = model.media(item.refId)
        let isLive = controls?.isMediaLive(item.refId) ?? false
        let tileShape = RoundedRectangle.standard(
            roundedCorners ? CornerStandard.element : 0
        )

        let across = SlidesAcross.resolved(
            slidesAcross, width: pageWidth - Self.pageMargin * 2, spacing: SlideGridMetrics.spacing)
        let row = SlidesAcross.rows(count: 1, across: across)[0]
        let radius = roundedCorners ? CornerStandard.element : 0
        return HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
            PosterImage(model: model, mediaId: item.refId)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black.opacity(0.35))
                .clipShape(tileShape)
                // Live as on the slide tiles: a red ring just outside, and the tag.
                .overlay {
                    if isLive {
                        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                            .strokeBorder(HopeStyle.live, lineWidth: 3)
                            .padding(-3)
                    } else {
                        tileShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isLive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(HopeStyle.live, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .padding(5)
                    }
                }

                .overlay {
                    if !isLive {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {

                    if let media { controls?.fire(mediaItem: media, context: .serviceItem(id: item.id)) }
                }

                .contextMenu { mediaQuickMenu(item) }

                .id("mediaTileMenu|\(item.id)|\(media == nil)")
                .frame(maxWidth: .infinity)
            ForEach(0 ..< row.fillers, id: \.self) { _ in
                Color.clear.frame(height: 0).frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Self.itemGap)
    }

    @ViewBuilder
    private func mediaContext(_ media: MediaItem) -> some View {
        HStack(spacing: 4) {
            if model.isMediaFileMissing(media) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("\u{201C}\(media.fileName)\u{201D} isn't on this Mac")
            }
            if media.inPoint != nil || media.outPoint != nil {
                Image(systemName: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Trimmed")
            }
            if media.loops {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Loops")
            }
            if let label = durationLabel(media) {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func durationLabel(_ media: MediaItem) -> String? {
        guard media.mediaKind == .video, let total = media.durationSeconds else { return nil }
        let effective = max(0, (media.outPoint ?? total) - (media.inPoint ?? 0))
        let seconds = Int(effective.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func displayName(_ item: ServiceItem) -> String {
        model.entry(item.refId)?.name ?? item.name
    }

    private func headerTint(_ item: ServiceItem) -> Color? {
        item.colorHex.flatMap(ColorHex.color).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
    }

    private func presentRows(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.ordered(
            service.items.filter { $0.applies(toTime: nil) && (!$0.isHidden || $0.itemKind == .header) },
            by: nil)
    }

    private func firePositions(_ service: Service) -> [FirePosition] {
        var positions: [FirePosition] = []
        for item in model.runOfShow(service) where item.itemKind == .presentation {

            guard let presentation = model.presentation(item.refId) else { continue }
            let slides = model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            for (index, slide) in slides.enumerated() {
                positions.append(FirePosition(
                    itemID: item.id, presentation: presentation,
                    arrangementId: item.arrangementId,
                    occurrence: index, slide: slide
                ))
            }
        }
        return positions
    }

    private func fireStep(_ delta: Int, _ positions: [FirePosition]) {
        guard let controls, !positions.isEmpty else { return }

        let settled = delta > 0 && NSEvent.modifierFlags.contains(.option)
        controls.advance(steps: delta, settled: settled) {
            // Empty presentations have no places, so a step skips them.
            let live = controls.liveContextID.flatMap { itemID in
                controls.liveOccurrence.map { PlanSlideSteps.Place(itemID: itemID, occurrence: $0) }
            }
            let places = positions.map { PlanSlideSteps.Place(itemID: $0.itemID, occurrence: $0.occurrence) }
            guard let next = PlanSlideSteps.step(delta, from: live, in: places) else { return }
            let position = positions[next]
            controls.fire(
                slide: position.slide, in: position.presentation,
                arrangementId: position.arrangementId,
                contextID: position.itemID, occurrence: position.occurrence
            )
        }
    }
}

private struct PillDropDelegate: DropDelegate {
    let index: Int
    let width: () -> CGFloat
    let setDropIndex: (Int?) -> Void

    let perform: (Int, String) -> Bool

    private func target(for info: DropInfo) -> Int {
        info.location.x < width() / 2 ? index : index + 1
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setDropIndex(target(for: info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setDropIndex(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertBefore = target(for: info)
        setDropIndex(nil)
        guard let provider = info.itemProviders(for: [.plainText, .text]).first
        else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                _ = perform(insertBefore, String(payload))
            }
        }
        return true
    }
}

extension ServiceContinuousView {

    func unlinkedCard(_ item: ServiceItem) -> some View {
        HStack(spacing: 8) {
            ItemKindBadge(kind: HopeStyle.kind(of: item, presentation: nil))
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if item.refId.isEmpty, item.mxuSongTitle != nil {
                GetLyricsButton(model: model, serviceID: serviceID, item: item)
            }
            if item.isCountdown == true, !runOnly {
                CountdownVideoMenu(model: model, planID: serviceID, item: item)
                    .fixedSize()
            }
            if let duration = item.duration, duration > 0 {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Not Linked")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )

        .padding(.bottom, 12)

        .id(Self.anchor(unlinked: item.id))
    }

    private func stickySection<Body: View, Header: View>(
        _ item: ServiceItem,
        @ViewBuilder body: () -> Body,
        @ViewBuilder header: () -> Header
    ) -> some View {
        let headerHeight = headerHeights[item.id] ?? 44
        let headerView = header()
        let bodyView = body()
        return ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: headerHeight)
                bodyView
            }
            GeometryReader { geo in
                let frame = geo.frame(in: .named(Self.scrollSpace))
                let stick = max(0, min(-frame.minY, geo.size.height - headerHeight))
                headerView

                    .fixedSize(horizontal: false, vertical: true)
                    .background(headerHeightReader(item))
                    .background { StuckHeaderBackdrop(margin: Self.pageMargin).opacity(stick > 0 ? 1 : 0) }
                    .frame(width: geo.size.width, alignment: .topLeading)
                    .offset(y: stick)
            }
            .zIndex(1)
        }
    }

    private func headerHeightReader(_ item: ServiceItem) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { if headerHeights[item.id] != geo.size.height { headerHeights[item.id] = geo.size.height } }
                .onChange(of: geo.size.height) { old, height in
                    if headerHeights[item.id] != height { headerHeights[item.id] = height }

                    if abs(height - old) > 300 {
                        DiagnosticsStore.shared.note(
                            "present.header", detail: "\"\(item.name)\" \(Int(old)) → \(Int(height)) pt")
                    }
                }
        }
    }

    static func anchor(unlinked itemID: String) -> String { "unlinked|" + itemID }

    static func anchor(for itemID: String, in service: Service) -> String {
        service.items.contains { $0.id == itemID && $0.itemKind == .info }
            ? anchor(unlinked: itemID) : itemID
    }

    private func scrollToFocus(
        _ itemID: String?, reason: String, proxy: ScrollViewProxy, service: Service
    ) {
        if let target = focusScroll.request(itemID) {
            DiagnosticsStore.shared.note("present.focus", detail: "scroll \(target) (\(reason))")
            InputTrailRecorder.shared.noteFocusScroll()
            withAnimation(reason == "appear" ? nil : jump) {
                proxy.scrollTo(Self.anchor(for: target, in: service), anchor: .top)
            }
            PresentCardFrames.shared.holdCard(target)
            PresentCardFrames.shared.reportLanding(target: target, rows: presentRows(service))
        } else if let itemID {
            DiagnosticsStore.shared.note("present.focus", detail: "hold \(itemID) (\(reason), already there)")
        }
    }

    /// A plan-list click glides to its item; landing on the page doesn't.
    private var jump: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    private func revealLive(_ service: Service, cause: String = "keyboard") {
        if let itemID = controls?.liveContextID, let occurrence = controls?.liveOccurrence,
           presentRows(service).contains(where: { $0.id == itemID }) {
            PresentCardFrames.shared.reveal(
                itemID, slide: occurrence, headerHeight: headerHeights[itemID] ?? 44, cause: cause)
        }
    }

    /// A slide went live some way other than an arrow key here. The page
    /// keeps it in view and the plan list highlights its item, except for a
    /// few seconds after the operator scrolls the page somewhere else; a
    /// clicked slide is already in view, so only the highlight moves. More
    /// slides of an item the operator picked away from never get here.
    private func followLive(_ itemID: String, _ service: Service) {
        guard presentRows(service).contains(where: { $0.id == itemID }) else { return }
        let recorder = InputTrailRecorder.shared
        let scroll = recorder.sincePageScroll(), key = recorder.sinceKey(), click = recorder.sinceClick()
        if PresentFollowRule.selectsLive(sinceScroll: scroll, sinceKey: key, sinceClick: click) {
            onShowItem?(itemID)
        }
        if PresentFollowRule.reveals(sinceScroll: scroll, sinceKey: key, sinceClick: click) {
            revealLive(service, cause: "live")
        }
    }
}

/// The operator's picks in the plan list, counted so picking the same item
/// twice still registers.
private struct PresentPicks: Equatable {
    private(set) var itemID: String?
    private(set) var count = 0

    mutating func pick(_ itemID: String?) {
        self.itemID = itemID
        count += 1
    }
}

/// Watches what's live for ServiceContinuousView, so a fire re-renders this
/// and not the page (see slideGridHostsNeverReadTheLiveSlide). An item the
/// operator picked away from is let go until another goes live
/// (PresentLiveHold), so a looping slideshow doesn't pull them back.
private struct LiveSlideFollow: View {
    let controls: ServiceControls?
    let picks: PresentPicks
    let follow: (String) -> Void

    @State private var hold = PresentLiveHold()

    var body: some View {
        Color.clear
            .onChange(of: picks) { _, picks in
                hold.selected(picks.itemID, live: controls?.liveContextID)
            }
            .onChange(of: place) { _, _ in
                if let itemID = controls?.liveContextID, hold.follows(live: itemID) { follow(itemID) }
            }
    }

    private var place: String? {
        controls?.liveContextID.map { "\($0)#\(controls?.liveOccurrence ?? -1)" }
    }
}

extension ServiceItem {

    var presentRowIdentity: String { id + "|" + itemKind.rawValue }
}

private struct CardRefresh<Content: View>: View {
    let model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        let _ = model.listVersion
        content()
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width
            maxX = max(maxX, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(
            width: width.isFinite ? width : maxX,
            height: subviews.isEmpty ? 0 : y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct ArrangementStrip: View {
    let model: AppModel
    let presentation: Presentation

    @Binding var selection: String?

    var showsPicker = true

    var onJump: ((Int) -> Void)?

    @Environment(\.runOnly) private var runOnly

    @State private var dropIndex: Int?

    @State private var pillWidths: [Int: CGFloat] = [:]

    private var sections: [PresentationSection] { presentation.sections ?? [] }
    private var arrangements: [Arrangement] { presentation.arrangements ?? [] }

    private var activeArrangement: Arrangement? {
        guard let id = selection, !id.isEmpty else { return nil }
        return arrangements.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsPicker {
                ArrangementPicker(model: model, presentation: presentation, selection: $selection)
            }

            WrapLayout(spacing: 4, lineSpacing: 4) {
                if let arrangement = activeArrangement {
                    arrangementPills(arrangement)
                    if !runOnly {
                        addBlockMenu(arrangement)
                    }
                } else {
                    baseOrderPills
                }
            }
            .padding(.vertical, 1)

            .padding(.leading, 5)
        }
    }

    private func setLive(_ arrangementID: String?) {
        selection = arrangementID
    }

    @ViewBuilder
    private var baseOrderPills: some View {
        let runs = baseRunSections
        ForEach(Array(runs.enumerated()), id: \.offset) { index, section in
            pill(section.name, section: section, prominent: false)
                .contentShape(Capsule())
                .onTapGesture { onJump?(index) }
        }
        if runs.isEmpty {
            Text("No sections")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var baseRunSections: [PresentationSection] {

        SlideSceneBuilder.arrangementBlockStarts(for: presentation).compactMap { start in
            sections.first { $0.id == presentation.slides[start].sectionId }
        }
    }

    @ViewBuilder
    private func arrangementPills(_ arrangement: Arrangement) -> some View {
        let count = arrangement.sectionIds.count
        ForEach(Array(arrangement.sectionIds.enumerated()), id: \.offset) { index, sectionId in
            pill(
                sectionName(sectionId),
                section: sections.first { $0.id == sectionId },
                prominent: true
            )

                .opacity(sectionIsEmpty(sectionId) ? 0.45 : 1)
                .help(
                    sectionIsEmpty(sectionId)
                        ? "\(sectionName(sectionId)) has no slides yet" : ""
                )
                .contentShape(Capsule())
                .onTapGesture { onJump?(index) }
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { pillWidths[index] = geo.size.width }
                            .onChange(of: geo.size.width) { _, width in
                                pillWidths[index] = width
                            }
                    }
                    .allowsHitTesting(false)
                )
                .overlay(alignment: .leading) {
                    if dropIndex == index { insertionBar.offset(x: -3) }
                }
                .overlay(alignment: .trailing) {

                    if index == count - 1, dropIndex == count {
                        insertionBar.offset(x: 3)
                    }
                }
                .draggablePayload(runOnly ? nil : "arrblock::\(presentation.id)::\(index)")

                .onDrop(of: [.plainText, .text], delegate: PillDropDelegate(
                    index: index,
                    width: { pillWidths[index] ?? 40 },
                    setDropIndex: { dropIndex = $0 },
                    perform: { insertBefore, payload in
                        guard !runOnly else { return false }
                        let applied = dropBlock(
                            payload, arrangement: arrangement, before: insertBefore
                        )

                        dropIndex = nil
                        return applied
                    }
                ))
                .contextMenu {
                    if !runOnly {
                        Button("Remove Section") {
                            model.updateArrangement(
                                presentation.id, arrangementID: arrangement.id
                            ) { $0.sectionIds.remove(at: index) }
                        }
                    }
                }
        }
    }

    private var insertionBar: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 14)
    }

    private func sectionIsEmpty(_ sectionId: String) -> Bool {
        !presentation.slides.contains { $0.sectionId == sectionId }
    }

    private func addBlockMenu(_ arrangement: Arrangement) -> some View {
        Menu {
            ForEach(sections) { section in
                let slideCount = presentation.slides.count { $0.sectionId == section.id }
                Button(
                    "\(section.name)  —  \(slideCount == 1 ? "1 slide" : "\(slideCount) slides")"
                ) {
                    model.updateArrangement(
                        presentation.id, arrangementID: arrangement.id
                    ) { $0.sectionIds.append(section.id) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a section")
    }

    private func dropBlock(
        _ payload: String, arrangement: Arrangement, before targetIndex: Int
    ) -> Bool {
        let parts = payload.components(separatedBy: "::")
        guard parts.count == 3, parts[0] == "arrblock", parts[1] == presentation.id,
              let from = Int(parts[2]), arrangement.sectionIds.indices.contains(from)
        else { return false }
        let to = targetIndex

        guard from != to, from + 1 != to else { return false }
        model.updateArrangement(presentation.id, arrangementID: arrangement.id) {
            guard $0.sectionIds.indices.contains(from) else { return }
            let block = $0.sectionIds.remove(at: from)
            let target = from < to ? to - 1 : to
            $0.sectionIds.insert(block, at: min(max(target, 0), $0.sectionIds.count))
        }
        return true
    }

    private func sectionName(_ id: String) -> String {
        sections.first { $0.id == id }?.name ?? "Deleted Section"
    }

    private func pill(_ name: String, section: PresentationSection?, prominent: Bool) -> some View {
        let hex = section?.resolvedColorHex(paletteColors: model.groupColors)
        let fill = hex.flatMap(GroupColor.color)
        // Outlined in the group's color, not filled: the tiles already carry
        // the colors, and the chips are for jumping, not reading.
        return Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(prominent ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                fill.map { $0.opacity(prominent ? 0.22 : 0.10) }
                    ?? Color.primary.opacity(prominent ? 0.08 : 0.04),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    (fill ?? Color.primary.opacity(0.35)).opacity(prominent ? 0.9 : 0.6), lineWidth: 1
                )
            )
    }
}

struct ArrangementPicker: View {
    let model: AppModel
    let presentation: Presentation
    @Binding var selection: String?

    @State private var renamingArrangement = false
    @State private var renameText = ""
    @Environment(\.runOnly) private var runOnly

    private var arrangements: [Arrangement] { presentation.arrangements ?? [] }

    private var activeArrangement: Arrangement? {
        guard let id = selection, !id.isEmpty else { return nil }
        return arrangements.first { $0.id == id }
    }

    private var chipTitle: String {
        let name = activeArrangement?.name ?? "Default"
        return name.count > 12 ? String(name.prefix(12)) + "…" : name
    }

    var body: some View {
        if runOnly {
            Text(chipTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            pickerMenu
        }
    }

    private var pickerMenu: some View {
        Menu {

            Toggle("Default", isOn: Binding(
                get: { selection?.isEmpty ?? true },
                set: { _ in selection = nil }
            ))
            if !arrangements.isEmpty {
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(arrangement.name, isOn: Binding(
                        get: { selection == arrangement.id },
                        set: { _ in selection = arrangement.id }
                    ))
                }
            }
            Divider()
            Button("New Arrangement") {

                model.addArrangement(presentation.id) { created in
                    selection = created.id
                }
            }
            if let arrangement = activeArrangement {
                Button("Rename\u{2026}") {
                    renameText = arrangement.name
                    renamingArrangement = true
                }
                Button("Delete \u{201C}\(arrangement.name)\u{201D}", role: .destructive) {
                    selection = nil
                    model.deleteArrangement(presentation.id, arrangementID: arrangement.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .font(.system(size: 9, weight: .semibold))
                Text(chipTitle)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(activeArrangement == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which arrangement plays here")
        .alert("Rename Arrangement", isPresented: $renamingArrangement) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let arrangement = activeArrangement, !trimmed.isEmpty {
                    model.updateArrangement(
                        presentation.id, arrangementID: arrangement.id
                    ) { $0.name = trimmed }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct CardSlidePosition: View {
    let controls: ServiceControls?
    let itemID: String
    let slideCount: Int

    var body: some View {
        Text(detail)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var detail: String {
        if controls?.liveContextID == itemID, let occurrence = controls?.liveOccurrence {
            "Slide \(occurrence + 1) of \(slideCount)"
        } else {
            slideCount == 0 ? "No slides" : slideCount == 1 ? "1 slide" : "\(slideCount) slides"
        }
    }
}

private struct EmptyDeckNewSlide: Identifiable {
    let presentationID: String
    let themeId: String
    let afterSlideID: String?
    var id: String { presentationID }
}

/// Behind an item header only while it is pinned at the top, so tiles
/// scrolling under it don't show through its text. It reaches over the page
/// margins to the edges.
private struct StuckHeaderBackdrop: View {
    let margin: CGFloat

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(Color.black.opacity(0.25))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            }
            .padding(.horizontal, -margin)
            .allowsHitTesting(false)
    }
}

/// What on an item's slides needs a look before the service, as one count in
/// its header rather than a triangle on every tile. Clicking it lists them.
private struct PresentationIssuesBadge: View {
    let model: AppModel
    let presentation: Presentation
    let arrangementId: String?
    let slides: [Slide]

    @State private var clippedSlideIDs: Set<String> = []
    @State private var listing = false

    private struct Issue: Identifiable {
        let id: String
        let number: Int
        let text: String
    }

    private struct CheckKey: Equatable {
        let presentation: Presentation
        let arrangementId: String?
        let themes: [Theme?]
    }

    /// Each slide once, numbered where it first plays.
    private var firstPlays: [(number: Int, slide: Slide)] {
        var seen = Set<String>()
        return slides.enumerated().compactMap { index, slide in
            seen.insert(slide.id).inserted ? (index + 1, slide) : nil
        }
    }

    private func theme(for slide: Slide) -> Theme? {
        slide.themeId != nil || slide.unthemed == true
            ? model.theme(for: slide, in: presentation) : model.theme(presentation.themeId)
    }

    private var issues: [Issue] {
        firstPlays.flatMap { number, slide -> [Issue] in
            var found: [Issue] = []
            let missing = MediaReferences.ids(in: slide).sorted().filter(model.isMediaMissing(mediaID:))
            if !missing.isEmpty {
                let names = missing.compactMap { model.media($0)?.name }
                found.append(Issue(
                    id: slide.id + "|media", number: number,
                    text: names.isEmpty
                        ? "A media file isn't on this Mac"
                        : "\u{201C}\(names.joined(separator: "\u{201D}, \u{201C}"))\u{201D} isn't on this Mac"))
            }
            if clippedSlideIDs.contains(slide.id) {
                found.append(Issue(
                    id: slide.id + "|text", number: number,
                    text: "Text doesn't fit its box; the overflow is cut off"))
            }
            return found
        }
    }

    var body: some View {
        let issues = issues
        let plays = firstPlays
        Group {
            if !issues.isEmpty {
                Button { listing.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("\(issues.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(issues.count == 1 ? "1 thing to check on these slides" : "\(issues.count) things to check on these slides")
                .popover(isPresented: $listing, arrowEdge: .bottom) { list(issues) }
            }
        }
        .task(id: CheckKey(presentation: presentation, arrangementId: arrangementId, themes: plays.map { theme(for: $0.slide) })) {
            let checks = plays.map { ($0.slide, theme(for: $0.slide)) }
            let presentation = presentation
            let clipped = await Task.detached(priority: .utility) {
                Set(checks.filter { slide, theme in
                    !SlideSceneBuilder.clippedTextObjectIDs(
                        for: slide, theme: theme, presentation: presentation
                    ).isEmpty
                }.map(\.0.id))
            }.value
            if clipped != clippedSlideIDs { clippedSlideIDs = clipped }
        }
    }

    private func list(_ issues: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues.prefix(12)) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Slide \(issue.number)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 58, alignment: .leading)
                    Text(issue.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if issues.count > 12 {
                Text("and \(issues.count - 12) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Fix text in Edit. Locate missing media from the Library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}
