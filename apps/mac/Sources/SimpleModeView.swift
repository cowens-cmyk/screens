import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

/// Simple Mode: the main window for a volunteer running a service. The
/// whole plan's slides on one page, top to bottom, each labelled with what
/// it is, and pinned above them in the middle what every screen is showing,
/// with Back, Next, Clear All and the sermon timer beside it. Clicking a
/// slide puts it up; the arrows, Space and Return step through the plan.
///
/// The page is Present's whole-plan page itself, under the run-only lock:
/// nothing on it edits (no Add Slide, no drops, no context menus). Nothing
/// here edits either: no library, no editor, no settings, no scheduler, no
/// plan or screens panels. It is the run-only lock
/// (PresentLayoutController.runOnly) with its own face, so it survives a
/// relaunch and leaving asks for the passcode.
struct SimpleModeView: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    /// The item the page is on, as the plan list's selection is in Present:
    /// the page moves it as it follows the show.
    @State private var itemID: String?
    @State private var focusScroll = PresentFocusScroll()
    @State private var exiting = false
    @FocusState private var keysHere: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let render {
                SimpleScreensBand(render: render, controls: controls, step: step) { keysHere = true }
            }
            page
        }
        .background { ShellBackdrop() }
        // The page takes the keys while it has focus; this is for when it
        // doesn't (after a button here, or a message sent to the stage).
        .focusable()
        .focusEffectDisabled()
        .focused($keysHere)
        .onPresentFireKeys { step($0) }
        .onChange(of: model.currentServiceID) {
            itemID = nil
            focusScroll.reset()
        }
        .navigationTitle(plan?.name ?? "Simple Mode")
        .toolbar {
            ToolbarItem(placement: .navigation) { planMenu }
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

    private var planMenu: some View {
        Menu {
            ForEach(upcomingPlans, id: \.id) { candidate in
                Button(candidate.name) { model.currentServiceID = candidate.id }
            }
        } label: {
            Label(plan?.name ?? "Choose a Plan", systemImage: "list.bullet.rectangle.portrait")
                .labelStyle(.titleAndIcon)
        }
        .help("Which plan to run")
    }

    // MARK: The slides

    @ViewBuilder
    private var page: some View {
        if let planID = model.currentServiceID {
            ServiceContinuousView(
                model: model, render: render, controls: controls,
                serviceID: planID, focusItemID: itemID,
                focusScroll: $focusScroll,
                onShowItem: { id in
                    focusScroll.follow(id)
                    itemID = id
                })
                // The page's run-only face, whatever brought Simple Mode up.
                .environment(\.runOnly, true)
                // A new plan starts at its top.
                .id(planID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HopeEmptyState(title: "No Plan", symbol: "list.bullet.rectangle.portrait",
                           message: "Choose this week's plan from the menu at the top left.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Through the whole plan, as the arrow keys go: past an item's last
    /// slide, Next starts the next item.
    private func step(_ direction: Int) {
        keysHere = true
        WindowBridge.advance?(direction)
    }
}

// MARK: The screens

/// Pinned over the page, in the middle: a live preview of each screen with
/// its name under it and a red edge while it shows something, then Back
/// and Next, Clear All, the sermon timer and a message to the stage. Its
/// own view, so a slide going live redraws the edges here and not the page.
private struct SimpleScreensBand: View {
    let render: RenderContext
    let controls: ServiceControls?
    let step: (Int) -> Void
    /// After typing (the stage message, the timer's minutes): the keys go
    /// back to running the show.
    let keysBack: () -> Void

    @AppStorage("monitors.hidden") private var hiddenScreens = ""
    @State private var width: CGFloat = 0

    private static let controlsWidth: CGFloat = 280
    private static let spacing: CGFloat = 12
    private static let previewWidths: ClosedRange<CGFloat> = 150 ... 250

    var body: some View {
        let screens = MonitorsPanel.shownScreens(render: render, setup: ShowSetup.shared, hiddenList: hiddenScreens)
            .filter { $0.target != nil }
        let previewWidth = previewWidth(count: screens.count)
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(screens) { screen in
                SimpleScreenPreview(render: render, controls: controls, screen: screen, width: previewWidth)
            }
            if screens.isEmpty {
                Text("No screens are set up. Settings › Screens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, height: 120)
            }
            if let controls {
                showControls(controls)
                    .frame(width: Self.controlsWidth)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    /// As wide as the window allows, between a size you can still read and
    /// one that leaves the slides most of the window.
    private func previewWidth(count: Int) -> CGFloat {
        guard count > 0, width > 0 else { return Self.previewWidths.upperBound }
        let room = width - 32 - Self.controlsWidth - Self.spacing * CGFloat(count)
        let each = (room / CGFloat(count)).rounded(.down)
        return min(max(each, Self.previewWidths.lowerBound), Self.previewWidths.upperBound)
    }

    private func showControls(_ controls: ServiceControls) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { step(-1) } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .help("Previous slide (←)")
                Button { step(1) } label: {
                    HStack(spacing: 6) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(HopeStyle.blue)
                .help("Next slide (→ or Space)")
            }
            Button { controls.clearAll() } label: {
                Label("Clear All", systemImage: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [.shift])
            .help("Clear every screen (⇧Esc)")
            SermonTimerControl(controls: controls, onDone: keysBack)
            StageMessageButton(controls: controls, onDone: keysBack)
        }
        .controlSize(.large)
    }
}

/// One screen: what it shows now, about 15 times a second, its name under
/// it, and a red edge while anything is up on it.
private struct SimpleScreenPreview: View {
    let render: RenderContext
    let controls: ServiceControls?
    let screen: MonitorsPanel.Entry
    let width: CGFloat

    private static let framesPerSecond: Float = 15

    var body: some View {
        let live = isShowing
        VStack(spacing: 5) {
            preview
                .frame(width: width, height: (width * 9 / 16).rounded())
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(live ? HopeStyle.live : Color.white.opacity(0.14), lineWidth: live ? 3 : 1))
            HStack(spacing: 6) {
                if live {
                    Circle().fill(HopeStyle.live).frame(width: 7, height: 7)
                }
                Text(screen.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(live ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: width)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(live ? "\(screen.title), showing" : screen.title)
    }

    @ViewBuilder
    private var preview: some View {
        if let target = screen.target {
            Group {
                if screen.role == .stream {
                    ZStack {
                        Checkerboard()
                        TransparentScenePreview(
                            compositor: render.compositor,
                            provider: render.outputs.previewProvider(for: target),
                            maximumFramesPerSecond: Self.framesPerSecond)
                    }
                } else if screen.role == .stage {
                    LiveSceneView(render: render, screenTargetID: target, maximumFramesPerSecond: Self.framesPerSecond)
                        .modifier(PreviewedLayoutKeeper(target: target))
                } else {
                    LiveSceneView(render: render, screenTargetID: target, maximumFramesPerSecond: Self.framesPerSecond)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// As the screens strip says it: anything up that Clear All would take
    /// down, and for the livestream only while it's on.
    private var isShowing: Bool {
        guard let controls, controls.hasAnyClearableContent else { return false }
        return screen.role != .stream || ShowSetup.shared.streamMode != .off
    }
}

/// A message to the stage, typed in a popover so the field never sits in
/// the way of the show's keys.
private struct StageMessageButton: View {
    let controls: ServiceControls
    let onDone: () -> Void
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Label("Message to Stage", systemImage: "text.bubble")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Show a message on the stage screen")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            StageMessageField(controls: controls) {
                shown = false
                onDone()
            }
            .padding(12)
            .frame(width: 300)
        }
    }
}
