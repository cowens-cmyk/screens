import AppKit
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

/// The zoom and pan of one editor's canvas, shared by everything drawn on it:
/// the Metal scene, the interaction layer (handles, guides, marquee, caret),
/// drops, the checkerboard and the Animate badges. The slide, theme, overlay
/// and stage layout editors all use the same canvas, so they all navigate
/// the same way.
///
/// The zoom lives only as long as the editor: opening an item starts at Fit,
/// and moving between its slides keeps the zoom, as Keynote does.
@MainActor
@Observable
final class CanvasNavigator {
    /// The stored zoom and pan. Read it through `resolved`, which falls back
    /// to Fit if the slide size has changed underneath it.
    private(set) var navigation: CanvasNavigation

    /// A pinch, a ⌘-scroll or an animated zoom is under way: the scene keeps
    /// its rasterised text and shapes, magnified, until it ends.
    @ObservationIgnored private(set) var interacting = false

    @ObservationIgnored private let canvasSizeProvider: () -> CGSize

    /// The canvas's size in points, as the interaction view last laid out.
    /// The scene, the interaction view and the SwiftUI layers all fill the
    /// same space, so they all resolve the same viewport.
    @ObservationIgnored private(set) var viewSize: CGSize = .zero

    @ObservationIgnored private weak var sceneView: MetalSceneView?
    @ObservationIgnored private var rasterAnchor: CGFloat?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var animation: Task<Void, Never>?

    init(canvasSize: @escaping () -> CGSize) {
        canvasSizeProvider = canvasSize
        navigation = CanvasNavigation(canvasSize: canvasSize(), inset: EditorGeometry.pasteboardInset)
    }

    var canvasSize: CGSize { canvasSizeProvider() }

    var resolved: CanvasNavigation {
        let size = canvasSizeProvider()
        guard navigation.canvasSize == size else {
            return CanvasNavigation(canvasSize: size, inset: EditorGeometry.pasteboardInset)
        }
        return navigation
    }

    func viewport(in size: CGSize) -> CanvasViewport { resolved.viewport(in: size) }

    /// A drop's slide point, for a view of `size`.
    func canvasPoint(fromView point: CGPoint, in size: CGSize) -> CGPoint {
        resolved.viewport(in: size).canvasPoint(fromView: point)
    }

    var isFit: Bool { resolved.isFit }

    func zoomPercent(in size: CGSize) -> Int { Int((resolved.scale(in: size) * 100).rounded()) }

    private var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    func noteViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        sceneView?.refreshViewport()
    }

    /// Hands the scene the current viewport, after anything that may have
    /// changed the slide's size.
    func refreshScene() {
        sceneView?.refreshViewport()
    }

    /// The Metal scene follows the viewport from its next frame on.
    func attach(_ view: MetalSceneView) {
        sceneView = view
        view.viewportResolver = { [weak self] size, backing in
            self?.sceneViewport(in: size, backing: backing)
        }
    }

    private func sceneViewport(in size: CGSize, backing: CGFloat) -> MetalSceneView.Viewport {
        let current = resolved
        let viewport = current.viewport(in: size)
        return MetalSceneView.Viewport(
            scale: viewport.scale, offset: viewport.offset,
            rasterScale: current.rasterScale(
                in: size, backing: backing, anchor: interacting ? rasterAnchor : nil))
    }

    private func update(_ change: (inout CanvasNavigation) -> Void) {
        var next = resolved
        change(&next)
        set(next)
    }

    private func set(_ next: CanvasNavigation) {
        if next != navigation { navigation = next }
        sceneView?.refreshViewport()
    }

    // MARK: Gestures

    /// Holds the scene's rasters at the scale the gesture began at; `end`
    /// renders it sharp again.
    func beginInteraction() {
        guard !interacting else { return }
        let backing = sceneView?.window?.backingScaleFactor ?? 2
        rasterAnchor = resolved.rasterScale(in: viewSize, backing: backing)
        interacting = true
    }

    func endInteraction() {
        settle?.cancel()
        settle = nil
        guard interacting, animation == nil else { return }
        interacting = false
        rasterAnchor = nil
        sceneView?.refreshViewport()
    }

    /// A mouse wheel has no phases, so its zoom ends a moment after the last
    /// notch.
    private func endInteractionSoon() {
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            self?.endInteraction()
        }
    }

    func magnify(by magnification: CGFloat, around point: CGPoint, phase: NSEvent.Phase) {
        cancelAnimation()
        if phase.contains(.began) || !interacting { beginInteraction() }
        update { $0.zoom(by: 1 + magnification, around: point, in: viewSize) }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            endInteraction()
        } else if phase.isEmpty {
            endInteractionSoon()
        }
    }

    /// ⌘ with a scroll: zoom about the pointer. A trackpad sends many small
    /// precise deltas, a mouse wheel a few whole lines.
    func scrollZoom(deltaY: CGFloat, precise: Bool, around point: CGPoint) {
        cancelAnimation()
        beginInteraction()
        let factor = exp(deltaY * (precise ? 0.01 : 0.1))
        update { $0.zoom(by: factor, around: point, in: viewSize) }
        endInteractionSoon()
    }

    /// Moves the slide with the fingers (or the dragging hand).
    func pan(by delta: CGSize) {
        guard delta != .zero else { return }
        cancelAnimation()
        update { $0.pan(by: delta, in: viewSize) }
    }

    /// The two-finger double tap: in to 100% (or twice Fit, if that's
    /// bigger) about the pointer, or back out to Fit.
    func smartMagnify(at point: CGPoint) {
        let current = resolved
        if current.isFit {
            var next = current
            next.zoom(to: max(1, current.fitScale(in: viewSize) * 2), around: point, in: viewSize)
            animate(to: next)
        } else {
            fit()
        }
    }

    // MARK: Commands

    func fit() {
        var next = resolved
        next.fit()
        animate(to: next)
    }

    /// 100%: one slide pixel per screen point, about the view's center.
    func actualSize() {
        zoom(to: 1)
    }

    func zoom(to scale: CGFloat) {
        var next = resolved
        next.zoom(to: scale, around: viewCenter, in: viewSize)
        animate(to: next)
    }

    /// ⌘+ and ⌘−: the next step, centred on the selection when there is one.
    func step(up: Bool, focus: CGRect?) {
        var next = resolved
        next.step(up: up, focus: focus.map { CGPoint(x: $0.midX, y: $0.midY) }, in: viewSize)
        animate(to: next)
    }

    func zoom(toSelection rect: CGRect) {
        var next = resolved
        next.zoom(toRect: rect, in: viewSize, margin: 48)
        animate(to: next)
    }

    /// A short eased move to `target`; straight there with Reduce Motion on,
    /// or before the canvas has a size.
    private func animate(to target: CanvasNavigation) {
        cancelAnimation()
        let start = resolved
        guard start != target else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              viewSize.width > 0, viewSize.height > 0 else {
            set(target)
            return
        }
        beginInteraction()
        let duration = 0.18
        let began = CACurrentMediaTime()
        animation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = min((CACurrentMediaTime() - began) / duration, 1)
                let eased = 1 - pow(1 - t, 3)
                self.set(CanvasNavigation.blend(from: start, to: target, t: eased, in: self.viewSize))
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard let self, !Task.isCancelled else { return }
            self.animation = nil
            self.endInteraction()
        }
    }

    private func cancelAnimation() {
        guard let running = animation else { return }
        running.cancel()
        animation = nil
    }
}

/// Watches the window's events for the canvas: pinch, two-finger scroll,
/// ⌘-scroll, Space-drag and middle-button drag, the two-finger double tap,
/// and the zoom keys while the canvas has focus. A local monitor rather than
/// overrides on the canvas view, because SwiftUI layers sit over parts of it
/// (the Animate badges, the zoom control) and would swallow scrolls and
/// pinches there; and because ⌘1 is the Present page in the menu, which only
/// a monitor can get to first.
@MainActor
final class CanvasGestureMonitor {
    private let navigator: CanvasNavigator
    private weak var view: NSView?

    /// The canvas has keyboard focus: no text box or field is being typed in.
    var canvasFocused: () -> Bool = { false }
    /// There is a slide on the canvas to move around.
    var enabled: () -> Bool = { true }
    /// The current selection's bounds on the slide, for ⌘+/⌘− and ⌥⌘0.
    var selectionBounds: () -> CGRect? = { nil }
    /// Space pressed and released without dragging: Animate's preview.
    var spaceTapped: (() -> Void)?
    /// Called after a pan or zoom so the view redraws its chrome.
    var changed: () -> Void = {}

    private var monitor: Any?
    private var spaceHeld = false
    private var spaceDragged = false
    private var panLast: CGPoint?
    private var pinching = false

    init(navigator: CanvasNavigator, view: NSView) {
        self.navigator = navigator
        self.view = view
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel, .magnify, .smartMagnify, .keyDown, .keyUp,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        releaseSpace()
        if panLast != nil { NSCursor.pop() }
        panLast = nil
        pinching = false
    }

    private func releaseSpace() {
        if spaceHeld { NSCursor.pop() }
        spaceHeld = false
        spaceDragged = false
    }

    private func local(_ event: NSEvent) -> CGPoint? {
        guard let view, let window = view.window, event.window === window else { return nil }
        return view.convert(event.locationInWindow, from: nil)
    }

    private func inside(_ event: NSEvent) -> CGPoint? {
        guard let view, let point = local(event), view.bounds.contains(point), enabled() else { return nil }
        return point
    }

    /// True when the event was the canvas's and nothing else should see it.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .magnify:
            if event.phase.contains(.began) { pinching = inside(event) != nil }
            guard pinching || (event.phase.isEmpty && inside(event) != nil),
                  let point = local(event) else { return false }
            navigator.magnify(by: event.magnification, around: point, phase: event.phase)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { pinching = false }
            changed()
            return true
        case .smartMagnify:
            guard let point = inside(event) else { return false }
            navigator.smartMagnify(at: point)
            changed()
            return true
        case .scrollWheel:
            guard let point = inside(event) else { return false }
            if event.modifierFlags.contains(.command) {
                navigator.scrollZoom(
                    deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, around: point)
            } else {
                // A wheel counts lines, a trackpad points.
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
                navigator.pan(by: CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
            }
            changed()
            return true
        case .keyDown:
            return keyDown(event)
        case .keyUp:
            guard event.keyCode == 49, spaceHeld else { return false }
            let tapped = !spaceDragged && panLast == nil
            releaseSpace()
            if tapped { spaceTapped?() }
            return true
        case .leftMouseDown:
            // The window may have lost the Space key-up to another app.
            if spaceHeld, !CGEventSource.keyState(.combinedSessionState, key: 49) { releaseSpace() }
            guard spaceHeld, let point = inside(event) else { return false }
            beginPan(at: point)
            spaceDragged = true
            return true
        case .otherMouseDown:
            guard event.buttonNumber == 2, let point = inside(event) else { return false }
            beginPan(at: point)
            return true
        case .leftMouseDragged, .otherMouseDragged:
            guard let last = panLast, let point = local(event) else { return false }
            navigator.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            panLast = point
            changed()
            return true
        case .leftMouseUp, .otherMouseUp:
            guard panLast != nil else { return false }
            panLast = nil
            NSCursor.pop()
            return true
        default:
            return false
        }
    }

    private func beginPan(at point: CGPoint) {
        if panLast != nil { NSCursor.pop() }
        panLast = point
        NSCursor.closedHand.push()
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        guard canvasFocused(), enabled() else { return false }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if !spaceHeld {
                spaceHeld = true
                spaceDragged = false
                NSCursor.openHand.push()
            }
            return true
        }
        guard let command = Self.zoomCommand(for: event) else { return false }
        perform(command)
        changed()
        return true
    }

    enum ZoomCommand { case fit, actualSize, zoomIn, zoomOut, zoomToSelection }

    /// ⌘0 Fit, ⌘1 100%, ⌘+ / ⌘= in, ⌘− out, ⌥⌘0 to the selection. ⌃⌘0
    /// (Reset Sermon Timer) and anything else with ⌃ pass by.
    static func zoomCommand(for event: NSEvent) -> ZoomCommand? {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.contains(.command), !mods.contains(.control),
              let key = event.charactersIgnoringModifiers else { return nil }
        let option = mods.contains(.option)
        switch key {
        case "0": return option ? .zoomToSelection : .fit
        case "1": return option ? nil : .actualSize
        case "=", "+": return option ? nil : .zoomIn
        case "-": return option ? nil : .zoomOut
        default: return nil
        }
    }

    func perform(_ command: ZoomCommand) {
        switch command {
        case .fit: navigator.fit()
        case .actualSize: navigator.actualSize()
        case .zoomIn: navigator.step(up: true, focus: selectionBounds())
        case .zoomOut: navigator.step(up: false, focus: selectionBounds())
        case .zoomToSelection:
            if let rect = selectionBounds() { navigator.zoom(toSelection: rect) }
        }
    }
}

extension SlideEditorModel {
    /// The selected objects' bounds on the slide (rotation included), which
    /// ⌘+, ⌘− and Zoom to Selection centre on.
    var canvasSelectionBounds: CGRect? {
        let frames = selectedObjects.map {
            EditorGeometry.rotatedBounds(displayFrame(for: $0), degrees: $0.rotationDegrees ?? 0)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
