import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

/// Simple Mode: the main window for a volunteer running a service. The
/// plan's items down the left, the chosen item's slides as big tiles in the
/// middle, the audience screen, a message to the stage and the sermon timer
/// on the right, and Back, Next and Clear All across the bottom. Nothing
/// here edits: no library, no editor, no settings, no scheduler, no context
/// menus, no drags. It is the run-only lock (PresentLayoutController.runOnly)
/// with its own face, so it survives a relaunch and leaving asks for the
/// passcode.
struct SimpleModeView: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    /// The item whose slides fill the middle. It follows the show: when
    /// Next moves into another item, that item opens.
    @State private var itemID: String?
    @State private var exiting = false
    @FocusState private var keysHere: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private static let sideWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                planColumn
                    .frame(width: 290)
                    .frame(maxHeight: .infinity)
                Divider()
                slidesColumn
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                sideColumn
                    .frame(width: Self.sideWidth)
                    .frame(maxHeight: .infinity)
            }
            Divider()
            transportBar
        }
        // The arrows, Space and Return run the show from anywhere in the
        // window, except while someone types a stage message.
        .focusable()
        .focusEffectDisabled()
        .focused($keysHere)
        .onPresentFireKeys { step($0) }
        .onAppear { keysHere = true; followLive() }
        .onChange(of: controls?.liveContextID) { followLive() }
        .onChange(of: model.currentServiceID) { itemID = nil; followLive() }
        .navigationTitle(plan?.name ?? "Simple Mode")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { exiting = true } label: {
                    Label("Exit Simple Mode", systemImage: "lock.open")
                        .labelStyle(.titleAndIcon)
                }
                .help("Back to the full app. Asks for the passcode.")
            }
        }
        .sheet(isPresented: $exiting) {
            PasscodeSheet(
                flow: .verify,
                verify: { layout?.verifyPIN($0) ?? false },
                waitSeconds: { layout?.pinWaitSeconds() ?? 0 }
            ) { _ in
                layout?.exitRunOnly(openWindow: openWindow, dismissWindow: dismissWindow)
            }
        }
    }

    // MARK: The plan

    private var plan: Service? {
        model.currentServiceID.flatMap { model.resident.services.value($0) }
    }

    /// Plans from today on, soonest first: a volunteer can open this week's
    /// plan without reaching the plan list.
    private var upcomingPlans: [Service] {
        let today = Self.dayFormatter.string(from: .now)
        return model.resident.services.values
            .filter { $0.isTemplate != true && (($0.serviceDate ?? "") >= today || $0.serviceDate == nil) }
            .sorted { ($0.serviceDate ?? "9999", $0.name) < ($1.serviceDate ?? "9999", $1.name) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var planColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                ForEach(upcomingPlans, id: \.id) { candidate in
                    Button(candidate.name) { model.currentServiceID = candidate.id }
                }
            } label: {
                Text(plan?.name ?? "Choose a Plan")
                    .font(.headline)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .help("Which plan to run")
            Divider()
            if let plan {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.runOfShow(plan), id: \.id) { item in
                                itemRow(item).id(item.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: controls?.liveContextID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            } else {
                Text("Choose this week's plan above.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ServiceItem) -> some View {
        if item.itemKind == .header {
            Text(item.name.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.horizontal, 6)
        } else {
            let live = isLive(item)
            let chosen = item.id == itemID
            Button {
                itemID = item.id
                keysHere = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: item))
                        .font(.system(size: 16))
                        .frame(width: 22)
                        .foregroundStyle(live ? Color.green : .secondary)
                    Text(item.name)
                        .font(.system(size: 17, weight: live ? .bold : .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if live {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    chosen ? HopeStyle.blue.opacity(0.35) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(live ? Color.green : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
        }
    }

    private func symbol(for item: ServiceItem) -> String {
        switch item.itemKind {
        case .presentation: "rectangle.on.rectangle"
        case .media: "film"
        case .audio, .playlist: "music.note"
        case .header, .info: "info.circle"
        }
    }

    private func isLive(_ item: ServiceItem) -> Bool {
        guard let controls else { return false }
        if controls.liveContextID == item.id { return true }
        return item.itemKind == .media && !item.refId.isEmpty && controls.isMediaLive(item.refId)
    }

    /// The live item opens by itself, so the middle always shows what Next
    /// is about to do; a volunteer's own pick stays until the show moves.
    private func followLive() {
        guard let plan else { return }
        let items = model.runOfShow(plan)
        if let live = items.first(where: isLive) {
            itemID = live.id
        } else if itemID == nil || !items.contains(where: { $0.id == itemID }) {
            itemID = items.first { $0.itemKind != .header }?.id
        }
    }

    // MARK: Slides

    private var chosenItem: ServiceItem? {
        guard let plan, let itemID else { return nil }
        return plan.items.first { $0.id == itemID }
    }

    @ViewBuilder
    private var slidesColumn: some View {
        if let item = chosenItem {
            switch item.itemKind {
            case .presentation:
                if let presentation = model.presentation(item.refId) {
                    slideGrid(item: item, presentation: presentation)
                } else if item.refId.isEmpty {
                    nothingToShow("“\(item.name)” has nothing linked to it yet.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .media:
                mediaTile(item)
            default:
                nothingToShow("“\(item.name)” has no slides.")
            }
        } else {
            nothingToShow(plan == nil ? "Choose a plan to start." : "Pick an item on the left.")
        }
    }

    private func nothingToShow(_ message: String) -> some View {
        Text(message)
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
    }

    private func slideGrid(item: ServiceItem, presentation: Presentation) -> some View {
        let slides = SlideSceneBuilder.arrangedSlides(for: presentation, arrangementId: item.arrangementId)
        let canvas = SlideSceneBuilder.canvasSize(for: presentation)
        let aspect = canvas.width / max(canvas.height, 1)
        let liveIndex = controls?.liveContextID == item.id ? controls?.liveOccurrence : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        Button {
                            controls?.fire(
                                slide: slide, in: presentation, arrangementId: item.arrangementId,
                                contextID: item.id, occurrence: index)
                            keysHere = true
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                SlideThumbnailView(
                                    model: model, render: render, slide: slide, presentation: presentation,
                                    theme: model.theme(for: slide, in: presentation),
                                    arrangementId: item.arrangementId,
                                    hideScopedBackgrounds: false, legibleText: false)
                                    .aspectRatio(aspect, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(slide.name.isEmpty ? "\(index + 1)" : "\(index + 1)  \(slide.name)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(index == liveIndex ? Color.green : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(index == liveIndex ? Color.green : .clear, lineWidth: 4))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(18)
            }
            .onChange(of: liveIndex) { _, index in
                if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private func mediaTile(_ item: ServiceItem) -> some View {
        let live = isLive(item)
        return VStack(spacing: 18) {
            PosterImage(model: model, mediaId: item.refId)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 560)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(live ? Color.green : .clear, lineWidth: 4))
            Button {
                controls?.fireServiceItem(item)
                keysHere = true
            } label: {
                Label(live ? "Playing" : "Play \(item.name)", systemImage: "play.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(live ? .green : HopeStyle.blue)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Audience, stage, sermon

    private var sideColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let render {
                    section("Audience") {
                        LiveSceneView(
                            render: render,
                            screenTargetID: ShowTargets(setup: ShowSetup.shared, render: render).audience)
                            .frame(width: Self.sideWidth - 32, height: ((Self.sideWidth - 32) * 9 / 16).rounded())
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    }
                }
                if let controls {
                    // Typing there takes the keys; sending gives them back.
                    section("Message to Stage") { StageMessageField(controls: controls) { keysHere = true } }
                    section("Sermon Timer") { SermonTimerControl(controls: controls) { keysHere = true } }
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Back, Next, Clear All

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button { step(-1) } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
            .help("Previous slide (←)")
            Button { step(1) } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .font(.system(size: 30, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(HopeStyle.blue)
            .help("Next slide (→ or Space)")
            .layoutPriority(1)
            Button { controls?.clearAll() } label: {
                Label("Clear All", systemImage: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(minWidth: 160, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Clear every screen")
        }
        .controlSize(.extraLarge)
        .padding(16)
        .background(.bar)
    }

    /// Through the whole plan, as the arrow keys go: past an item's last
    /// slide, Next starts the next item.
    private func step(_ direction: Int) {
        keysHere = true
        WindowBridge.advance?(direction)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.title
            configuration.icon
        }
    }
}
