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

/// A slide grid's one drop target, for its tiles and the space around them.
/// Each tile used to carry its own, and making one for every tile was a large
/// part of what a row of tiles cost to build during a glide; a drop target
/// also needs its place on screen, so SwiftUI came back to every built tile
/// on each frame of a scroll. The grid knows where its tiles are, so it finds
/// the tile under the pointer itself.
///
/// On a tile: a slide goes before or after it by the half it is over; a
/// picture, a video or files go before, onto or after it; anything else (a
/// macro, a track) goes onto it. Around the tiles: a picture, a video or a
/// slide goes in beside the nearest tile, and nothing else is taken.
struct SlideGridDropDelegate: DropDelegate {
    let enabled: Bool
    /// The tile under a point in the grid's own space.
    let tile: (CGPoint) -> SlideDropPlacement.TileHit?
    /// The place beside the nearest tile, for a point in the space around them.
    let gap: (CGPoint) -> SlideDropPlacement.Target?
    let gapAccepts: (DraggedPayload) -> Bool
    /// Whether a dragged id can go in beside a tile (a picture or video).
    let goesBeside: (String) -> Bool
    let show: (SlideDropPlacement.Target?) -> Void
    let dropStarted: () -> Void
    let performOnTile: (SlideDropPlacement.TileHit, SlideDropPlacement.Target, DraggedPayload) -> Bool
    let performInGap: (SlideDropPlacement.Target, DraggedPayload) -> Bool

    private struct Place {
        var target: SlideDropPlacement.Target
        var hit: SlideDropPlacement.TileHit?
    }

    private var draggedText: String? { NSPasteboard(name: .drag).string(forType: .string) }

    private func dragged(_ info: DropInfo) -> SlideDropPlacement.Dragged {
        let text = draggedText
        if GutterDropDelegate.forcesInsert(payload: text) { return .slide }
        if !info.hasItemsConforming(to: [.fileURL]), let text, !goesBeside(text) { return .other }
        return .media
    }

    private func place(_ info: DropInfo) -> Place? {
        if let hit = tile(info.location) {
            let target = SlideDropPlacement.target(
                overTile: hit.index, x: hit.x, width: hit.width, dragged: dragged(info))
            return Place(target: target, hit: hit)
        }
        guard gapAccepts(.current), let target = gap(info.location) else { return nil }
        return Place(target: target, hit: nil)
    }

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.plainText, .fileURL])
    }

    func dropEntered(info: DropInfo) { show(place(info)?.target) }
    func dropExited(info: DropInfo) { show(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let place = place(info) else {
            show(nil)
            return DropProposal(operation: .cancel)
        }
        show(place.target)
        return DropProposal(operation: GutterDropDelegate.forcesInsert(payload: draggedText) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let described = info.itemProviders(for: [.plainText, .fileURL])
            .map { $0.registeredTypeIdentifiers.joined(separator: "+") }
            .joined(separator: " | ")
        MainActor.assumeIsolated { DropLatency.performed() }
        DiagnosticsStore.shared.note("grid.drop.perform", detail: described)
        let payload = DraggedPayload.current
        let place = place(info)
        dropStarted()
        guard enabled, let place else { return false }
        guard let hit = place.hit else {
            DiagnosticsStore.shared.note("grid.gapDrop", detail: "\(place.target) files=\(payload.files.count)")
            return performInGap(place.target, payload)
        }
        DiagnosticsStore.shared.note(
            "grid.drop.tile",
            detail: "\(place.target) files=\(payload.files.count) \(payload.text?.prefix(40) ?? "")")
        if payload.text != nil || !payload.files.isEmpty {
            return performOnTile(hit, place.target, payload)
        }
        // Nothing on the drag pasteboard: the id comes from the drop itself.
        // Never for a place after the tile, which only media gets.
        if case .after = place.target { return false }
        guard let provider = info.itemProviders(for: [.plainText]).first else {
            DiagnosticsStore.shared.note("grid.drop.noTextProvider")
            return false
        }
        let typeIdentifier = provider.registeredTypeIdentifiers.first ?? "public.utf8-plain-text"
        // Runs on the main actor, as every drop here does.
        nonisolated(unsafe) let performOnTile = performOnTile
        let target = place.target
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            DispatchQueue.main.async {
                DiagnosticsStore.shared.note(
                    "grid.drop.loadCallback",
                    detail: "bytes=\(data?.count ?? -1) error=\(error.map(String.init(describing:)) ?? "nil")")
                guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    DiagnosticsStore.shared.note("grid.drop.textLoadFailed", detail: typeIdentifier)
                    return
                }
                _ = performOnTile(hit, target, DraggedPayload(text: text, files: []))
            }
        }
        return true
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
        guard enabled, info.hasItemsConforming(to: [.plainText, .fileURL]) else { return false }
        let payload = DraggedPayload.current
        // A tile dragged from the media bin can hold its id back until it's
        // dropped, so there's nothing to check yet: it's checked on the drop.
        if payload.text == nil, payload.files.isEmpty { return true }
        return accepts(payload)
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
        // The id wasn't on the drag pasteboard: read it from the drop itself.
        guard let provider = info.itemProviders(for: [.plainText, .text]).first else { return false }
        // Both run on the main actor, as every drop here does.
        nonisolated(unsafe) let accepts = accepts
        nonisolated(unsafe) let performText = performText
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, !text.isEmpty else { return }
            Task { @MainActor in
                if accepts(DraggedPayload(text: text, files: [])) { _ = performText(text) }
            }
        }
        return true
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
