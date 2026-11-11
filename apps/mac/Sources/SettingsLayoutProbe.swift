#if DEBUG
import AppKit
import SwiftUI

/// Settings layout checks without screenshots (other apps can't capture this
/// Mac's screen): SCREENS_SETTINGS_PROBE lists the panes to open and the
/// window sizes to open them at, e.g.
/// "integrations:lightkey@1030x710,general@min,stage@min~end" (~end scrolls
/// to the bottom). Each one is drawn to a PNG in SCREENS_SETTINGS_PROBE_DIR,
/// and the window's frames go to stderr, with any view that reaches past the
/// window's edges. Run it on a test library with MXU_SKIP_KEYCHAIN=1, as it
/// opens every pane it is given.
@MainActor
enum SettingsLayoutProbe {
    static let environmentKey = "SCREENS_SETTINGS_PROBE"

    struct Shot {
        let category: SettingsCategory
        let tab: IntegrationTab?
        /// nil is the window's minimum size.
        let size: CGSize?
        let name: String
        let scrollsToEnd: Bool
    }

    static func start() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env[environmentKey], !spec.isEmpty else { return }
        let folder = URL(fileURLWithPath: env["SCREENS_SETTINGS_PROBE_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shots = spec.split(separator: ",").compactMap { parse(String($0)) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            checkSegmentsFallback(into: folder)
            for shot in shots { await take(shot, into: folder) }
            log("settings probe: done")
        }
    }

    private static func parse(_ item: String) -> Shot? {
        let parts = item.replacingOccurrences(of: "~end", with: "").split(separator: "@", maxSplits: 1).map(String.init)
        let where_ = parts[0].split(separator: ":").map(String.init)
        guard let category = SettingsCategory(rawValue: where_[0]) else {
            log("settings probe: no section \(where_[0])")
            return nil
        }
        let tab = where_.count > 1 ? IntegrationTab(rawValue: where_[1]) : nil
        // "…@WxH~end" scrolls the pane to its end.
        let scrollsToEnd = item.hasSuffix("~end")
        var size: CGSize?
        if parts.count > 1, parts[1] != "min" {
            let wh = parts[1].split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { size = CGSize(width: wh[0], height: wh[1]) }
        }
        let name = item.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "@", with: "-").replacingOccurrences(of: "~", with: "-")
        return Shot(category: category, tab: tab, size: size, name: name, scrollsToEnd: scrollsToEnd)
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true && $0.isVisible }
    }

    private static func take(_ shot: Shot, into folder: URL) async {
        if let tab = shot.tab { UserDefaults.standard.set(tab.rawValue, forKey: IntegrationTab.defaultsKey) }
        NSApp.activate()
        SettingsRouter.shared.open(shot.category)
        // The responder-chain action needs a key window; the app menu's
        // Settings… item works without one.
        if settingsWindow() == nil, let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: index)
        }
        for _ in 0..<20 where settingsWindow() == nil {
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(600))
        guard let window = settingsWindow() else {
            log("settings probe: no Settings window; windows \(NSApp.windows.map { $0.identifier?.rawValue ?? "?" })")
            return
        }
        let target = shot.size ?? window.contentMinSize
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: target))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .milliseconds(1200))
        guard let content = window.contentView else { return }
        if shot.scrollsToEnd,
           let scroll = find(in: content, where: { ($0 as? NSScrollView).map { $0.frame.width > 400 && $0.documentView != nil } ?? false }) as? NSScrollView,
           let document = scroll.documentView {
            let end = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(600))
        }
        var lines = ["settings probe \(shot.name): frame \(window.frame) content \(content.bounds.size) min \(window.contentMinSize) title \"\(window.title)\" toolbar \(window.toolbar?.identifier ?? "none") style \(window.toolbarStyle.rawValue) items \(window.toolbar?.items.map { "\($0.itemIdentifier.rawValue)\($0.isHidden ? "(hidden)" : "")" } ?? [])"]
        report(content, in: content, depth: 0, into: &lines)
        log(lines.joined(separator: "\n"))
        // The frame view, so the title bar and toolbar are in the picture.
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The sidebar's glass doesn't draw into a cached image (it comes out
        // blank), so its list is drawn in on its own over a light fill; the
        // list draws itself in light colours when cached.
        if let glass = find(in: view, where: { $0 is NSGlassEffectView }),
           let list = find(in: glass, where: { String(describing: type(of: $0)).contains("OutlineListView") }),
           let listRep = list.bitmapImageRepForCachingDisplay(in: list.visibleRect) {
            list.cacheDisplay(in: list.visibleRect, to: listRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.9, alpha: 1).setFill()
            view.convert(glass.bounds, from: glass).fill()
            let listFrame = view.convert(list.visibleRect, from: list)
            listRep.draw(in: listFrame)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Picking a segment the way a click does should switch the tab.
        if shot.tab != nil, let control = find(in: content, where: { $0 is NSSegmentedControl }) as? NSSegmentedControl {
            let before = UserDefaults.standard.string(forKey: IntegrationTab.defaultsKey) ?? "?"
            control.selectedSegment = (control.selectedSegment + 1) % control.segmentCount
            control.sendAction(control.action, to: control.target)
            try? await Task.sleep(for: .milliseconds(400))
            log("settings probe: segment click \(before) → \(UserDefaults.standard.string(forKey: IntegrationTab.defaultsKey) ?? "?"), control shows \(control.label(forSegment: control.selectedSegment) ?? "?")")
        }
        let url = folder.appendingPathComponent("settings-\(shot.name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("settings probe: wrote \(url.path)")
    }

    /// The tabs as a row of segments where they fit, a pop-up where not.
    private static func checkSegmentsFallback(into folder: URL) {
        struct Holder: View {
            @State var tab = IntegrationTab.lightkey
            var body: some View {
                SettingsSegments(choices: IntegrationTab.allCases, title: \.title, selection: $tab)
                    .padding(10).background(Color.basePlane)
            }
        }
        for width in [700.0, 400.0] {
            let host = NSHostingView(rootView: Holder().frame(width: width))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 60)
            host.layoutSubtreeIfNeeded()
            var kinds: [String] = []
            func walk(_ v: NSView) {
                let kind = String(describing: type(of: v))
                if v is NSSegmentedControl || v is NSPopUpButton || kind.contains("PopUp") || kind.contains("Segmented") {
                    kinds.append("\(kind) \(v.convert(v.bounds, to: host))")
                }
                v.subviews.forEach(walk)
            }
            walk(host)
            log("settings probe: segments at \(Int(width)): \(kinds)")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("segments-\(Int(width)).png"))
            }
        }
    }

    private static func find(in view: NSView, where test: (NSView) -> Bool) -> NSView? {
        if test(view) { return view }
        for sub in view.subviews { if let hit = find(in: sub, where: test) { return hit } }
        return nil
    }

    /// The split view's panes, and anything drawn outside the window.
    private static func report(_ view: NSView, in root: NSView, depth: Int, into lines: inout [String]) {
        let frame = view.convert(view.bounds, to: root)
        let outside = frame.minX < -0.5 || frame.maxX > root.bounds.width + 0.5
        let kind = String(describing: type(of: view))
        let interesting = ["Outline", "Glass", "Search", "SegmentedControl"].contains { kind.contains($0) }
        if (depth <= 6 && (view is NSSplitView || kind.contains("Split") || outside)) || interesting {
            lines.append(String(repeating: "  ", count: min(depth, 8)) + "\(kind) \(frame)\(outside ? " OUTSIDE" : "")\(view.isHidden ? " hidden" : "")\(view.alphaValue < 1 ? " alpha \(view.alphaValue)" : "")\((view as? NSTableView).map { " rows \($0.numberOfRows)" } ?? "")")
        }
        guard depth < 30 else { return }
        for sub in view.subviews { report(sub, in: root, depth: depth + 1, into: &lines) }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
