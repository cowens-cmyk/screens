import AppKit
import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum DropLatency {
    static var performedAt: ContinuousClock.Instant?

    static var awaitingPaint: Set<String> = []

    static var relaidStamped = false

    static func sincePerform() -> String? {
        performedAt.map { at in
            let elapsed = at.duration(to: .now)
            return elapsed < .seconds(10) ? "\(elapsed)" : nil
        } ?? nil
    }

    static func performed() {
        performedAt = .now
        awaitingPaint = []
        relaidStamped = false
    }

    static func relaid(count: Int) {
        if !relaidStamped, let since = sincePerform() {
            relaidStamped = true
            DiagnosticsStore.shared.note("grid.drop.relaid", detail: "\(since) \(count) slides")
        }
    }

    static func painted(_ slideID: String, detail: String) {
        if awaitingPaint.remove(slideID) != nil, let since = sincePerform() {
            DiagnosticsStore.shared.note("grid.drop.painted", detail: "\(since) \(detail)")
            if awaitingPaint.isEmpty {
                performedAt = nil
            }
        }
    }
}

struct GutterDropDelegate: DropDelegate {
    let enabled: Bool

    var breadcrumb: String = "grid.drop"
    let dropStarted: () -> Void
    let setLine: (Bool) -> Void
    let setRing: (Bool) -> Void
    let performText: (String, Bool) -> Bool
    let performFiles: ([URL], Bool) -> Void

    var insertOnly = false

    var acceptPrefixes: [String]?

    var rejectPrefixes: [String]?

    var rowHeight: (() -> CGFloat)?

    var tileWidth: (() -> CGFloat)?
    var setLineAfter: (Bool) -> Void = { _ in }
    var performTextAfter: ((String) -> Bool)?

    /// A slide grid's tile: media near its trailing edge goes in after it,
    /// and both edges widen with the tile (SlideDropPlacement), so the place
    /// past the last slide can be reached from its tile.
    var mediaAfter: ((String) -> Bool)?
    var filesAfter: (([URL]) -> Void)?
    /// Whether a dragged id can go in beside the tile; anything else (a
    /// macro, a track) is only ever dropped onto it.
    var goesBeside: ((String) -> Bool)?

    private func isAfterZone(_ info: DropInfo) -> Bool {
        if !isReorder {
            return false
        } else if let rowHeight {
            let height = rowHeight()
            return height > 0 && info.location.y > height / 2
        } else if let tileWidth {
            let width = tileWidth()
            return width > 0 && info.location.x > width / 2
        } else {
            return false
        }
    }

    private var insertZone: CGFloat { 26 }

    private func isInsert(_ info: DropInfo) -> Bool {
        info.location.x < insertZone
    }

    /// Where media lands on a slide grid's tile: before, onto or after it.
    /// Nil everywhere else, where the old strip and halves still decide.
    private func mediaTarget(_ info: DropInfo) -> SlideDropPlacement.Target? {
        guard let tileWidth, mediaAfter != nil || filesAfter != nil, !insertOnly, !isReorder else { return nil }
        if !info.hasItemsConforming(to: [.fileURL]), let goesBeside,
           let text = NSPasteboard(name: .drag).string(forType: .string), !goesBeside(text) {
            return .onto(0)
        }
        return SlideDropPlacement.target(overTile: 0, x: info.location.x, width: tileWidth())
    }

    static func forcesInsert(payload: String?) -> Bool {
        guard let payload else { return false }
        return payload.hasPrefix("mxueditslide::") || payload.hasPrefix("mxuslide::")
            || payload.hasPrefix("mxuobj::")
    }

    private var isReorder: Bool {
        Self.forcesInsert(payload: NSPasteboard(name: .drag).string(forType: .string))
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard enabled, info.hasItemsConforming(to: [.plainText, .fileURL]) else { return false }

        let payload = NSPasteboard(name: .drag).string(forType: .string)
        if let rejectPrefixes, let payload,
           rejectPrefixes.contains(where: { payload.hasPrefix($0) }) {
            return false
        }
        guard let acceptPrefixes else { return true }
        guard let payload else { return false }
        return acceptPrefixes.contains { payload.hasPrefix($0) }
    }

    func dropEntered(info: DropInfo) {
        updateFeedback(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateFeedback(info)

        return DropProposal(operation: isReorder ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        setLine(false)
        setRing(false)
        setLineAfter(false)
    }

    private func updateFeedback(_ info: DropInfo) {
        if let target = mediaTarget(info) {
            setLine(target == .before(0))
            setRing(target == .onto(0))
            setLineAfter(target == .after(0))
            return
        }
        if isAfterZone(info) {
            setLine(false)
            setRing(false)
            setLineAfter(true)
            return
        }
        setLineAfter(false)
        let insert = insertOnly || isInsert(info) || isReorder
        setLine(insert)
        setRing(!insert)
    }

    func performDrop(info: DropInfo) -> Bool {
        let described = info.itemProviders(for: [.plainText, .fileURL])
            .map { $0.registeredTypeIdentifiers.joined(separator: "+") }
            .joined(separator: " | ")
        MainActor.assumeIsolated { DropLatency.performed() }
        DiagnosticsStore.shared.note("\(breadcrumb).perform", detail: described)
        let media = mediaTarget(info)
        let insert = media.map { $0 == .before(0) } ?? isInsert(info)
        let after = isAfterZone(info)
        dropStarted()
        setLine(false)
        setRing(false)
        setLineAfter(false)
        guard enabled else { return false }
        if after, let performTextAfter,
           let text = NSPasteboard(name: .drag).string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).after", detail: String(text.prefix(40)))
            return performTextAfter(text)
        }

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if media == .after(0) {
            DiagnosticsStore.shared.note("\(breadcrumb).mediaAfter", detail: "files=\(fileURLs.count)")
            if !fileURLs.isEmpty, let filesAfter {
                filesAfter(fileURLs)
                return true
            }
            if let text = dragPasteboard.string(forType: .string), !text.isEmpty, let mediaAfter {
                return mediaAfter(text)
            }
            return false
        }
        if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, insert)
            return true
        }
        if let text = dragPasteboard.string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "\(breadcrumb).pasteboard", detail: String(text.prefix(40)))
            return performText(text, insert)
        }

        guard let provider = info.itemProviders(for: [.plainText]).first else {
            DiagnosticsStore.shared.note("\(breadcrumb).noTextProvider")
            return false
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first ?? "public.utf8-plain-text"
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in

            DispatchQueue.main.async {
                DiagnosticsStore.shared.note(
                    "\(breadcrumb).loadCallback",
                    detail: "bytes=\(data?.count ?? -1) error=\(error.map(String.init(describing:)) ?? "nil")")
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    DiagnosticsStore.shared.note(
                        "\(breadcrumb).textLoadFailed", detail: typeIdentifier)
                    return
                }
                _ = performText(text, insert)
            }
        }
        return true
    }
}

/// What's on the drag pasteboard: a library id or slide drag as text, or
/// files from the Finder. Read the way the slide lists read it, so a media
/// bin tile's id and a Finder selection both arrive whole.
struct DraggedPayload {
    var text: String?
    var files: [URL]

    static var current: DraggedPayload {
        let pasteboard = NSPasteboard(name: .drag)
        let files = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = pasteboard.string(forType: .string)
        return DraggedPayload(text: text?.isEmpty == true ? nil : text, files: files)
    }
}

/// The space around a slide grid's tiles: the gaps between them, under a
/// row, and past the last one. A picture or video, or a slide, dropped there
/// goes in beside the nearest tile, shown by the same line the tiles use.
struct GridGapDropDelegate: DropDelegate {
    let enabled: Bool
    /// The place for a point in the grid's own space.
    let target: (CGPoint) -> SlideDropPlacement.Target?
    let accepts: (DraggedPayload) -> Bool
    let show: (SlideDropPlacement.Target?) -> Void
    let performText: (String, SlideDropPlacement.Target) -> Bool
    let performFiles: ([URL], SlideDropPlacement.Target) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL]) && accepts(.current)
    }

    func dropEntered(info: DropInfo) { show(target(info.location)) }
    func dropExited(info: DropInfo) { show(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        show(target(info.location))
        let text = NSPasteboard(name: .drag).string(forType: .string)
        return DropProposal(operation: GutterDropDelegate.forcesInsert(payload: text) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        show(nil)
        guard enabled, let place = target(info.location) else { return false }
        let payload = DraggedPayload.current
        DiagnosticsStore.shared.note("grid.gapDrop", detail: "\(place) files=\(payload.files.count)")
        if !payload.files.isEmpty {
            performFiles(payload.files, place)
            return true
        }
        if let text = payload.text {
            return performText(text, place)
        }
        return false
    }
}

/// One place that takes a library id or files from the Finder, lit while
/// something it takes is over it: the plan's countdown, which takes a video
/// from the media bin or the Finder.
struct PayloadDropDelegate: DropDelegate {
    let enabled: Bool
    let accepts: (DraggedPayload) -> Bool
    let targeted: (Bool) -> Void
    let performText: (String) -> Bool
    let performFiles: ([URL]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL]) && accepts(.current)
    }

    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        guard enabled else { return false }
        let payload = DraggedPayload.current
        if !payload.files.isEmpty { return performFiles(payload.files) }
        if let text = payload.text { return performText(text) }
        return false
    }
}

/// File URLs from dropped items, in the order they were dragged.
@MainActor
func droppedFileURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        if let url { urls.append(url) }
    }
    return urls
}

struct CanvasDropDelegate: DropDelegate {
    let enabled: Bool

    /// The drop's slide point, through the canvas's zoom and pan.
    let scenePoint: (CGPoint) -> CGPoint
    let setTargeted: (Bool) -> Void
    let performText: (String, CGPoint) -> Bool
    let performFiles: ([URL], CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL])
    }

    func dropEntered(info: DropInfo) { setTargeted(true) }
    func dropExited(info: DropInfo) { setTargeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        guard enabled else { return false }
        let point = scenePoint(info.location)
        DiagnosticsStore.shared.note(
            "editor.canvasDrop",
            detail: "x=\(Int(point.x)) y=\(Int(point.y))")

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURLs = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            DiagnosticsStore.shared.note("editor.canvasDrop.files", detail: "\(fileURLs.count)")
            performFiles(fileURLs, point)
            return true
        }
        if let text = dragPasteboard.string(forType: .string), !text.isEmpty {
            DiagnosticsStore.shared.note(
                "editor.canvasDrop.pasteboard", detail: String(text.prefix(40)))
            return performText(text, point)
        }
        DiagnosticsStore.shared.note("editor.canvasDrop.noPayload")
        return false
    }
}
