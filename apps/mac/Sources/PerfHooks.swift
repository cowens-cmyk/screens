#if DEBUG || MXU_PERF_HOOKS
import AppKit
import PresenterCore
import QuartzCore

@MainActor
enum PerfHooks {
    nonisolated static let notificationPrefix = "com.example.mxuslides.perf."

    private static weak var editor: SlideEditorModel?
    /// The app's render context, for the inputs that set screens' outputs.
    private static weak var render: RenderContext?

    /// The plan list picks the next item, as a click on it does.
    static let pickNext = Notification.Name("PerfHooks.pickNext")
    /// The Present page puts the next slide up, as the right arrow does.
    static let fireNext = Notification.Name("PerfHooks.fireNext")

    static func start(model: AppModel, render: RenderContext? = nil) {
        self.render = render
        guard let spec = ProcessInfo.processInfo.environment[PerfScenario.environmentKey] else { return }
        guard let scenario = PerfScenario(spec) else {
            DiagnosticsStore.shared.note("perf.scenario.failed", detail: "cannot read \(spec)")
            return
        }
        observe(["mark", "targets", "play", "stop", "pick", "fire", "input"])
        Task { await run(scenario, spec: spec, model: model) }
    }

    private static func run(_ scenario: PerfScenario, spec: String, model: AppModel) async {
        DiagnosticsStore.shared.note("perf.scenario", detail: spec)
        guard await waitFor({ model.isLibraryReady ? true : nil }) != nil else {
            return fail("the library never opened")
        }
        fitWindow()
        switch scenario {
        case .idle:
            ready(center: nil, handle: nil)
        case .present:
            // Headers and items as a Sunday has them; the library's decks
            // stand in for the songs, the announcements and the message.
            let decks = model.entries(in: .presentations).sorted { $0.name < $1.name }
            guard decks.count >= 14 else { return fail("only \(decks.count) decks") }
            var items: [ServiceItem] = []
            var next = 0
            for (header, count) in [("Countdown", 1), ("Opening Song", 3), ("Worship", 4), ("Message", 3), ("Closing Song", 3)] {
                items.append(ServiceItem(id: UUID().uuidString, itemKind: .header, name: header, refId: ""))
                for _ in 0 ..< count {
                    let deck = decks[next]
                    next += 1
                    items.append(ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: deck.name, refId: deck.id))
                }
            }
            let plan = Service(id: UUID().uuidString, name: "Perf Sunday", serviceDate: "2030-01-06", items: items)
            _ = model.createInDrive(plan)
            model.currentServiceID = plan.id
            UserDefaults.standard.set(true, forKey: PlanShell.wholePlanKey)
            UserDefaults.standard.set(AppMode.present.rawValue, forKey: "appMode")
            try? await Task.sleep(for: .seconds(5))
            ready(center: nil, handle: nil)
        case .animate(let themeName, let layout):
            guard let editor = await open(named: themeName, in: .themes, model: model) else { return }
            guard let slide = editor.presentation.slides.first(where: { $0.name == layout }) else {
                return fail("no layout named \(layout)")
            }
            editor.selectSlide(slide.id)
            editor.editorMode = .animate
            try? await Task.sleep(for: .seconds(1))
            ready(center: nil, handle: nil)
        case .edit(let deckName, let number, let objectName):
            guard let editor = await open(named: deckName, in: .presentations, model: model) else { return }
            let slides = editor.presentation.slides
            guard slides.indices.contains(number - 1) else { return fail("\(deckName) has no slide \(number)") }
            editor.selectSlide(slides[number - 1].id)
            guard let object = editor.currentSlide?.objects.first(where: { $0.name == objectName }) else {
                return fail("slide \(number) has no object named \(objectName)")
            }
            editor.selectObject(id: object.id)
            try? await Task.sleep(for: .seconds(1))
            let points = canvas(showing: editor.presentation.id)?.perfPressPoints(objectID: object.id)
            ready(center: points?.center, handle: points?.handle)
        }
    }

    private static func open(named name: String, in section: LibrarySection, model: AppModel) async -> SlideEditorModel? {
        guard let entry = model.entries(in: section).first(where: { $0.name == name }) else {
            fail("no \(section) entry named \(name)")
            return nil
        }
        UserDefaults.standard.set(AppMode.edit.rawValue, forKey: "appMode")
        model.selectedSection = section
        model.librarySelection = [entry.id]
        guard let opened = await waitFor({ canvas(showing: entry.id)?.perfEditor }) else {
            fail("the editor never opened \(name)")
            return nil
        }
        editor = opened
        return opened
    }

    private static func waitFor<T>(_ value: () -> T?) async -> T? {
        for _ in 0..<600 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func fitWindow() {
        guard let screen = NSScreen.main,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }
        window.setFrame(screen.visibleFrame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func canvas(showing id: String) -> EditorInteractionNSView? {
        for window in NSApp.windows where window.isVisible {
            if let found = window.contentView.flatMap({ find(in: $0, id: id) }) { return found }
        }
        return nil
    }

    private static func find(in view: NSView, id: String) -> EditorInteractionNSView? {
        if let canvas = view as? EditorInteractionNSView, canvas.window != nil, canvas.bounds.width > 0,
           canvas.perfEditor.presentation.id == id {
            return canvas
        }
        for subview in view.subviews {
            if let found = find(in: subview, id: id) { return found }
        }
        return nil
    }

    private static func ready(center: CGPoint?, handle: CGPoint?) {
        DiagnosticsStore.shared.note("perf.scenario.ready", detail: PerfScenario.readyDetail(center: center, handle: handle))
    }

    private static func fail(_ why: String) {
        DiagnosticsStore.shared.note("perf.scenario.failed", detail: why)
    }

    private static func observe(_ names: [String]) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    let signal = (name?.rawValue as String?)?.replacingOccurrences(of: PerfHooks.notificationPrefix, with: "")
                    DispatchQueue.main.async { MainActor.assumeIsolated { PerfHooks.signal(signal ?? "") } }
                },
                (notificationPrefix + name) as CFString, nil, .deliverImmediately)
        }
    }

    /// Posts the mouse or key event described in ~/perf-input.txt into the
    /// app's own event queue, so it takes the path a real one does (hit
    /// testing, the list's own mouse tracking, gestures, key handlers). For
    /// measuring and checking clicks where no real pointer can reach the
    /// window (a locked screen, a headless run). One line:
    ///   click X Y [left|right|double] [cmd|shift]   (window points, origin top left)
    ///   key KEYCODE [cmd|shift]
    ///   scroll DY COUNT          (COUNT wheel events of DY points, a frame apart, to the plan page)
    ///   menu X Y                 (the right-click menu SwiftUI gives at that point; its items go to perf.menu)
    ///   dragover X Y PAYLOAD     (a drag carrying PAYLOAD, or file:PATH, held over that point)
    ///   drop X Y PAYLOAD         (the same drag, dropped there; what the drop target answered goes to perf.drop)
    ///   dragend                  (the held drag leaves)
    ///   port NAME ID SCREEN      (a DeckLink port, real or not, given a screen: audience, sideTVs, livestream, stage, none)
    ///   display UUID SCREEN      (a display, connected or not, given a screen)
    ///   routes                   (every screen's outputs, to perf.routes)
    ///   quit                     (quits as the menu does, without asking)
    /// For menu, dragover and drop, `tile N ACROSS` in place of X Y is a
    /// point on tile N of the topmost slide grid showing it whole: ACROSS
    /// of its width from its leading edge (0.5 the middle, 0.1 and 0.9 its
    /// edges, 1.03 the gap after it).
    /// A point on a slide tile, in window points from the top left.
    private static func pointOnTile(_ tile: Int, across: Double, in window: NSWindow) -> CGPoint? {
        let showing = SlideGridClicks.shared.grids.compactMap { grid -> CGRect? in
            guard grid.window === window, !grid.isHiddenOrHasHiddenAncestor,
                  let frame = grid.frames?()[tile], grid.visibleRect.contains(frame)
            else { return nil }
            let inWindow = grid.convert(frame, to: nil)
            return CGRect(
                x: inWindow.minX, y: window.frame.height - inWindow.maxY,
                width: inWindow.width, height: inWindow.height)
        }
        return showing.min { $0.minY < $1.minY }.map {
            CGPoint(x: $0.minX + $0.width * across, y: $0.minY + $0.height * 0.4)
        }
    }

    private static var heldDrag: PerfDrag?
    private static weak var heldTarget: NSView?

    private static func postInput() {
        let path = NSHomeDirectory() + "/perf-input.txt"
        guard let line = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first,
            let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })
        else {
            DiagnosticsStore.shared.note("perf.input", detail: "nothing to post")
            return
        }
        var parts = line.split(separator: " ").map(String.init)
        if parts.count >= 4, parts[1] == "tile", let tile = Int(parts[2]), let across = Double(parts[3]) {
            guard let point = pointOnTile(tile, across: across, in: window) else {
                DiagnosticsStore.shared.note("perf.input", detail: "\(line): no grid shows tile \(tile) whole")
                return
            }
            parts.replaceSubrange(1...3, with: [String(Double(point.x)), String(Double(point.y))])
        }
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("shift") { flags.insert(.shift) }
        let now = ProcessInfo.processInfo.systemUptime
        if !NSApp.isActive { NSApp.activate() }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        switch parts.first {
        case "click":
            guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            let point = NSPoint(x: x, y: window.frame.height - y)
            let right = parts.contains("right")
            let clicks = parts.contains("double") ? 2 : 1
            for click in 1...clicks {
                for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: flags, timestamp: now,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: click, pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "scroll":
            guard parts.count >= 3, let dy = Int32(parts[1]), let count = Int(parts[2]),
                  let scrollView = PresentCardFrames.shared.scrollView
            else { return }
            RowBuildLog.begin()
            Task { @MainActor in
                for _ in 0 ..< count {
                    if let wheel = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
                       let event = NSEvent(cgEvent: wheel) {
                        InputTrailRecorder.shared.notePerfPageScroll()
                        scrollView.scrollWheel(with: event)
                    }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        case "port":
            guard parts.count >= 4, let id = Int64(parts[2]), let render = Self.render else { return }
            let device = DeckLinkHelperDevice(
                name: parts[1].replacingOccurrences(of: "_", with: " "), persistentID: id,
                supportsPlayback: true, supportsInternalKeying: true, supportsExternalKeying: true)
            ScreenRouting.setPort(device, to: ShowScreen(rawValue: parts[3]), render: render)
        case "display":
            guard parts.count >= 3, let render = Self.render else { return }
            ScreenRouting.assign(display: parts[1], to: ShowScreen(rawValue: parts[2]), render: render)
        case "routes":
            guard let render = Self.render else { return }
            let routes = ShowScreen.allCases.map { role -> String in
                guard let output = ScreenOutput(role, render: render) else { return "\(role.rawValue)=off" }
                var ways: [String] = []
                if let display = output.display { ways.append("display:\(display)") }
                ways += output.deckLinkBackings.map { "port:\($0.deviceName.replacingOccurrences(of: " ", with: "_"))" }
                if output.ndiOn { ways.append("ndi") }
                return "\(role.rawValue)=" + (ways.isEmpty ? "none" : ways.sorted().joined(separator: "+"))
            }
            DiagnosticsStore.shared.note("perf.routes", detail: routes.joined(separator: " "))
        case "quit":
            AppDelegate.quitsWithoutAsking = true
            NSApp.terminate(nil)
        case "menu":
            guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            let point = NSPoint(x: x, y: window.frame.height - y)
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: flags, timestamp: now,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            // What a real right-click goes through: the click watcher sees
            // it first, then the view under it is asked for its menu.
            SlideGridClicks.shared.saw(event)
            var view = window.contentView?.superview?.hitTest(point) ?? window.contentView
            var menu: NSMenu?
            while let candidate = view, menu == nil {
                menu = candidate.menu(for: event)
                view = candidate.superview
            }
            let titles = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
            DiagnosticsStore.shared.note(
                "perf.menu", detail: "\(Int(x)) \(Int(y)): \(titles.count) items: \(titles.prefix(8).joined(separator: " | "))")
        case "dragover", "drop", "dragend":
            // The view AppKit would send the drag to: the one under the
            // point that takes dragged types (SwiftUI lays one, which no
            // click can hit, over each drop target). The smallest wins, as
            // the innermost drop target does.
            let dragPoint: NSPoint? = parts.count >= 3
                ? Double(parts[1]).flatMap { x in Double(parts[2]).map { NSPoint(x: x, y: window.frame.height - $0) } }
                : nil
            var takers: [NSView] = []
            func walk(_ view: NSView) {
                if !view.registeredDraggedTypes.isEmpty, !view.isHiddenOrHasHiddenAncestor,
                   let dragPoint, view.convert(view.bounds, to: nil).contains(dragPoint) {
                    takers.append(view)
                }
                view.subviews.forEach(walk)
            }
            var root: NSView? = window.contentView
            while let up = root?.superview { root = up }
            if let root { walk(root) }
            let under = takers.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let target = under ?? (parts.first == "dragend" ? heldTarget : nil) else {
                if let held = heldDrag, let heldTarget { heldTarget.draggingExited(held) }
                heldDrag = nil
                DiagnosticsStore.shared.note("perf.drop", detail: "\(parts[1]) \(parts[2]): nothing there takes a drag")
                return
            }
            if let held = heldDrag, let heldTarget, heldTarget !== target {
                heldTarget.draggingExited(held)
                heldDrag = nil
            }
            heldTarget = target
            if parts.first == "dragend" {
                if let held = heldDrag { target.draggingExited(held) }
                heldDrag = nil
                break
            }
            guard parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            let payload = parts[3...].joined(separator: " ")
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            if payload.hasPrefix("file:") {
                pasteboard.writeObjects([URL(fileURLWithPath: String(payload.dropFirst(5))) as NSURL])
            } else {
                pasteboard.setString(payload, forType: .string)
            }
            let drag = PerfDrag(window: window, location: NSPoint(x: x, y: window.frame.height - y))
            let entered = heldDrag == nil ? target.draggingEntered(drag) : target.draggingUpdated(drag)
            let updated = target.draggingUpdated(drag)
            heldDrag = drag
            if parts.first == "drop" {
                let prepared = target.prepareForDragOperation(drag)
                let performed = prepared && target.performDragOperation(drag)
                target.concludeDragOperation(drag)
                heldDrag = nil
                DiagnosticsStore.shared.note(
                    "perf.drop",
                    detail: "\(Int(x)) \(Int(y)): entered \(entered.rawValue) updated \(updated.rawValue) performed \(performed)")
            } else {
                DiagnosticsStore.shared.note(
                    "perf.drop", detail: "\(Int(x)) \(Int(y)): entered \(entered.rawValue) updated \(updated.rawValue) held by \(Int(target.frame.width))x\(Int(target.frame.height))")
            }
        case "key":
            guard parts.count >= 2, let code = UInt16(parts[1]) else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: now,
                    windowNumber: window.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        default:
            return
        }
        DiagnosticsStore.shared.note(
            "perf.input", detail: "\(line) (active \(NSApp.isActive), key \(window.isKeyWindow))")
    }

    private static func signal(_ name: String) {
        switch name {
        case "mark":
            let bodies = DiagnosticsStore.shared.bodyMeter.withLock {
                $0.drainMark(names: MeteredView.allCases.map(\.name))
            }
            DiagnosticsStore.shared.note("perf.mark", detail: bodies)
        case "targets":
            let points = editor.flatMap { editor in
                editor.selectedObjectIDs.first.flatMap {
                    canvas(showing: editor.presentation.id)?.perfPressPoints(objectID: $0)
                }
            }
            DiagnosticsStore.shared.note(
                "perf.targets", detail: PerfScenario.readyDetail(center: points?.center, handle: points?.handle))
        case "play":
            if let editor {
                editor.previewRepeats = true
                editor.playAnimationPreview()
                DiagnosticsStore.shared.note("perf.play", detail: "\(editor.animationPreviewDuration) s on repeat")
            }
        case "stop":
            editor?.stopAnimationPreview()
        case "pick":
            NotificationCenter.default.post(name: pickNext, object: nil)
        case "fire":
            NotificationCenter.default.post(name: fireNext, object: nil)
        case "input":
            postInput()
        default:
            break
        }
    }
}

/// A drag that isn't one, for the `dragover` and `drop` inputs: what a drop
/// target is told about a drag, with what it carries on the drag pasteboard.
final class PerfDrag: NSObject, NSDraggingInfo {
    private let window: NSWindow
    private let location: NSPoint

    init(window: NSWindow, location: NSPoint) {
        self.window = window
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    // What AppKit's own drag keeps for a drop target between its calls;
    // SwiftUI's hosting view asks for it.
    private var lastOperation: UInt = 0
    @objc func _lastDragDestinationOperation() -> UInt { lastOperation }
    @objc func _setLastDragDestinationOperation(_ operation: UInt) { lastOperation = operation }
}
#endif
