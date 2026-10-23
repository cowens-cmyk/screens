import PresenterCore
import SwiftUI

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Screens is always dark: it runs in a dark booth, and every window,
    /// sheet and menu matches. The stored choice is ignored.
    var colorScheme: ColorScheme? {
        .dark
    }
}

struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isRestorable = false }
    }
}

@MainActor
enum WindowBridge {
    static var openMain: (() -> Void)?

    static var openPreview: ((String) -> Void)?
    /// Next (1) or Back (-1) through the whole plan, exactly as the arrow
    /// keys do; Simple Mode's big buttons use it.
    static var advance: ((Int) -> Void)?
    static var previewScreens: (() -> [(id: String, name: String)])?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Dark everywhere, including AppKit menus, alerts and panels.
        MainActor.assumeIsolated { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }

    /// Double-clicked .screenstheme / .screenspres files import themselves.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ShareOpenQueue.open(urls) }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            if let main = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                if main.isMiniaturized { main.deminiaturize(nil) }
                main.makeKeyAndOrderFront(nil)
            } else {
                WindowBridge.openMain?()
            }
        }
        return true
    }
}

@main
struct MxUSlidesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var renderContext: RenderContext?
    @State private var appModel: AppModel?

    @State private var controls: ServiceControls?

    @State private var streamRouter: StreamRouter?

    @State private var presentLayout = PresentLayoutController()

    @State private var localAPI: LocalAPIController?

    @State private var actionRouter: ActionRouter?

    @State private var confidenceMonitor: ConfidenceMonitorController?

    @State private var scheduler: SchedulerController?

    @State private var midiIn: MIDIInController?

    @State private var keyIn: KeyInController?

    @State private var serviceTracking: ServiceTimingController?

    @State private var assistant: AssistantSession?

    init() {

        BackupSettings.applyPending()

        DiagnosticsStore.shared.activate()

        MainThreadOpenTrap.armAtLaunch()
        MenuTrackingRecorder.shared.activate()

        InputTrailRecorder.shared.activate()

        SheetWatchRecorder.shared.activate()

        FeedbackController.shared.activate()

        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 250,
        ])

        NDINetworkScope.apply()
        NDINetworkScope.watchNetworkChanges()
        let render = RenderContext()

        UserDefaults.standard.set(AppMode.present.rawValue, forKey: "appMode")
        let model = AppModel()
        #if DEBUG || MXU_PERF_HOOKS

        PerfHooks.start(model: model)
        #endif
        _renderContext = State(initialValue: render)
        _appModel = State(initialValue: model)
        ShareOpenQueue.model = model
        var assistantRouter: ActionRouter?
        if let render {
            let controls = ServiceControls(appModel: model, render: render)
            let stream = StreamRouter(
                appModel: model, outputs: render.outputs, controls: controls
            )
            let confidence = ConfidenceMonitorController(
                appModel: model, render: render, controls: controls
            )
            let router = ActionRouter(
                model: model, controls: controls, stream: stream,
                confidenceMonitor: confidence
            )
            controls.actionRouter = router
            assistantRouter = router
            AnthemLink.shared.attach(model: model, controls: controls)
            _actionRouter = State(initialValue: router)
            _confidenceMonitor = State(initialValue: confidence)
            let schedulerController = SchedulerController(
                model: model, controls: controls, router: router
            )
            _scheduler = State(initialValue: schedulerController)
            _controls = State(initialValue: controls)
            _streamRouter = State(initialValue: stream)
            let api = LocalAPIController(
                appModel: model, controls: controls,
                render: render,
                scheduler: schedulerController
            )
            _localAPI = State(initialValue: api)
            MIDIDeviceInventory.shared.configure(model: model)

            let midiIn = MIDIInController(
                model: model, controls: controls, router: router, bridge: api.bridge
            )
            midiIn.attach()
            _midiIn = State(initialValue: midiIn)

            let keyIn = KeyInController(
                model: model, controls: controls, router: router, bridge: api.bridge
            )
            keyIn.attach()
            _keyIn = State(initialValue: keyIn)
            WindowBridge.advance = { [weak keyIn] steps in
                keyIn?.perform(steps > 0 ? .nextSlide : .previousSlide)
            }
            ShepherdSync.shared.attach(model)
            PlanTimeBridge.shared.start(model)
            LiveAssist.shared.attach(model: model, controls: controls)
            AppUpdater.shared.start()
            let tracking = ServiceTimingController(model: model, controls: controls, render: render)
            controls.serviceTracking = tracking
            _serviceTracking = State(initialValue: tracking)
        }
        _assistant = State(initialValue: AssistantSession(model: model, router: assistantRouter))
    }

    var body: some Scene {

        WindowGroup("Screens", id: "main") {
            if let appModel, appModel.libraryOpenError != nil {

                Text("Could not open the library.")
                    .padding(40)
            } else if let appModel, !appModel.isLibraryReady {

                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the library…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(minWidth: 1000, minHeight: 600)
            } else if let appModel {

                PlanShell(
                    model: appModel, render: renderContext,
                    controls: controls,
                    layout: presentLayout
                )
                .environment(\.actionRouter, actionRouter)
                .environment(\.scheduler, scheduler)
                .environment(\.confidenceMonitor, confidenceMonitor)

                .overlay(alignment: .bottom) {
                    GoToSlideHUD(keyIn: keyIn).padding(.bottom, 48)
                }
                // Sidebar 180 + slides 320 + screens 360, with room to spare.
                .frame(minWidth: 1000, minHeight: 640)

                .sheet(isPresented: $showWelcome) {
                    OnboardingView(
                        model: appModel, importWorkspace: welcomeImportAction
                    ) { showWelcome = false }
                }
                .onChange(of: showWelcome) { appModel.welcomeShowing = showWelcome }
                .task {
                    // Sheets wait until the window has laid out once: one
                    // presented during the split view's first layout loops
                    // AppKit's constraint pass until it kills the app.
                    try? await Task.sleep(for: .seconds(1))
                    if appModel.needsOnboarding && !presentLayout.runOnly {
                        showWelcome = true
                    }
                }

                .sheet(isPresented: $showFeedback) {
                    FeedbackView(model: appModel) { showFeedback = false }
                }
                .task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if FeedbackController.shared.lastRunCrashed && !showWelcome && !presentLayout.runOnly {
                        showFeedback = true
                    }
                }
                .task { await actionRouter?.runStartupCombos() }
                .task { await scheduler?.start() }
            } else {
                Text("Could not open the library.")
                    .padding(40)
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 900)
        .commands {
            LibraryCommands()
            EditorCommands(journal: appModel?.moveUndo)
            ViewCommands()
            PresentCommands()
            HelpCommands(model: appModel, showWelcome: $showWelcome, showFeedback: $showFeedback)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await AppUpdater.shared.check(userInitiated: true) } }
            }
        }

        Settings {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "Settings")
                    .frame(width: 420, height: 260)
            } else {
                AppSettingsView(
                    model: appModel, controls: controls, layout: presentLayout,
                    api: localAPI)
            }
        }

        WindowGroup(id: "module", for: ServiceControlsModule.self) { $module in
            if let appModel, let module {
                ModuleWindowView(
                    module: module, model: appModel,
                    controls: controls, layout: presentLayout
                )
                .environment(\.confidenceMonitor, confidenceMonitor)
            }
        }
        .defaultSize(width: 360, height: 460)

        Window("Service Controls", id: "serviceControls") {
            if let appModel {
                ServiceControlsWindowView(
                    model: appModel, controls: controls,
                    layout: presentLayout
                )
                .environment(\.confidenceMonitor, confidenceMonitor)
                .environment(\.actionRouter, actionRouter)
                .environment(\.scheduler, scheduler)
            }
        }
        .defaultSize(width: 420, height: 520)

        WindowGroup(id: "preview", for: String.self) { $target in
            PreviewWindowView(
                render: renderContext, controls: controls, layout: presentLayout,
                target: target ?? ""
            )

            .environment(\.confidenceMonitor, confidenceMonitor)
        }
        .defaultSize(width: 640, height: 380)

        Window("Screen Configuration", id: "outputs") {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "Screen Configuration")
                    .background(NonRestorableWindow())
            } else {
                OutputsWindow(render: renderContext)
                    .background(NonRestorableWindow())
            }
        }
        .defaultSize(width: 780, height: 540)

        Window("Live Assist", id: "liveAssist") {
            LiveAssistView()
        }
        .defaultSize(width: 400, height: 600)
        .keyboardShortcut("l", modifiers: [.command, .option])

        // Opened from Window › Assistant or the main window's toolbar
        // (openWindow(id: "assistant")). It edits the library, so Run-Only
        // locks it like Settings.
        Window("Assistant", id: "assistant") {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "Assistant")
                    .background(NonRestorableWindow())
            } else if let assistant {
                AssistantView(session: assistant)
            }
        }
        .defaultSize(width: 460, height: 700)
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }

    @Environment(\.openWindow) private var openWindow

    @State private var showWelcome = false

    @State private var showFeedback = false

    private var welcomeImportAction: ((@escaping (ImportActivityModel?) -> Void) -> Void)? {
        if let appModel, let renderContext, let controls {
            { host in
                WorkspaceImportRunner(
                    model: appModel, render: renderContext, controls: controls,
                    confidenceMonitor: confidenceMonitor,
                    inlineHost: host
                ).present()
            }
        } else {
            nil
        }
    }

}
