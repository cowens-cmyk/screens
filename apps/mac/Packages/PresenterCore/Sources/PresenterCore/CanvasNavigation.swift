import CoreGraphics
import Foundation

/// How a slide maps onto an editor canvas: view points per slide pixel, and
/// where the slide's top-left corner lands in the view. Every editor surface
/// (the rendered scene, the handles and guides, the text caret, drops and the
/// Animate badges) converts through one of these, so they can't drift apart.
public struct CanvasViewport: Equatable, Sendable {
    public var scale: CGFloat
    public var offset: CGPoint

    public init(scale: CGFloat, offset: CGPoint) {
        self.scale = scale
        self.offset = offset
    }

    public func viewPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
    }

    public func canvasPoint(fromView point: CGPoint) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    public func viewRect(fromCanvas rect: CGRect) -> CGRect {
        CGRect(
            x: offset.x + rect.minX * scale, y: offset.y + rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale)
    }

    public func canvasRect(fromView rect: CGRect) -> CGRect {
        guard scale > 0 else { return rect }
        let origin = canvasPoint(fromView: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / scale, height: rect.height / scale)
    }
}

/// The zoom and pan of an editor canvas, kept apart from the view's size so
/// the scene, the interaction layer and the SwiftUI overlays (which each
/// measure the same space) resolve the same viewport. Fit follows the view as
/// it resizes; any other zoom keeps the slide point at the view's center.
///
/// Zoom is view points per slide pixel, so 100% shows a 1920×1080 slide 1920
/// points wide: one slide pixel per screen point, the way Keynote counts.
public struct CanvasNavigation: Equatable, Sendable {
    public static let minimumZoom: CGFloat = 0.1
    public static let maximumZoom: CGFloat = 8

    /// The share of the slide's on-screen width (and height) that panning
    /// must leave in view, so the slide can't be lost off the edge. Zoomed
    /// far in, half the view is enough: the pasteboard past the slide's edge
    /// stays reachable.
    public static let keptInView: CGFloat = 0.2

    /// ⌘+ and ⌘− walk these, the zooms people expect from Keynote.
    public static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 6, 8]

    /// The longest side, in pixels, the whole slide is ever rasterised at.
    /// Text and shapes are drawn into CPU bitmaps at their on-screen size, so
    /// at 800% a title would need a bitmap far past what Metal or memory
    /// allow. Past this the canvas magnifies a render that is already twice
    /// the screens' own resolution for a 1080p slide.
    public static let maximumRasterDimension: CGFloat = 4096

    public var canvasSize: CGSize
    /// The margin Fit leaves around the slide (the pasteboard).
    public var inset: CGFloat
    /// nil while fitting the view.
    public private(set) var zoom: CGFloat?
    /// The slide point at the view's center, when not fitting.
    public private(set) var center: CGPoint

    public init(canvasSize: CGSize, inset: CGFloat) {
        self.canvasSize = canvasSize
        self.inset = inset
        zoom = nil
        center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    public init(canvasSize: CGSize, inset: CGFloat, zoom: CGFloat, center: CGPoint) {
        self.canvasSize = canvasSize
        self.inset = inset
        self.zoom = zoom
        self.center = center
    }

    public var isFit: Bool { zoom == nil }

    private var hasCanvas: Bool { canvasSize.width > 0 && canvasSize.height > 0 }

    public func fitScale(in view: CGSize) -> CGFloat {
        guard hasCanvas, view.width > 0, view.height > 0 else { return 1 }
        return min(
            max(view.width - 2 * inset, 1) / canvasSize.width,
            max(view.height - 2 * inset, 1) / canvasSize.height)
    }

    /// The zooms this view allows: Fit may sit below 10% in a tiny window.
    public func zoomRange(in view: CGSize) -> ClosedRange<CGFloat> {
        let fit = fitScale(in: view)
        return min(Self.minimumZoom, fit) ... max(Self.maximumZoom, fit)
    }

    public func scale(in view: CGSize) -> CGFloat {
        zoom ?? fitScale(in: view)
    }

    public func viewport(in view: CGSize) -> CanvasViewport {
        let scale = scale(in: view)
        guard zoom != nil else {
            return CanvasViewport(scale: scale, offset: CGPoint(
                x: (view.width - canvasSize.width * scale) / 2,
                y: (view.height - canvasSize.height * scale) / 2))
        }
        let kept = Self.clampedCenter(center, scale: scale, canvas: canvasSize, view: view)
        return CanvasViewport(scale: scale, offset: CGPoint(
            x: view.width / 2 - kept.x * scale,
            y: view.height / 2 - kept.y * scale))
    }

    /// The slide's position limits along one axis: at least `keptInView` of
    /// its on-screen length overlaps the view (or half the view, whichever
    /// is less).
    static func clampedCenter(_ center: CGPoint, scale: CGFloat, canvas: CGSize, view: CGSize) -> CGPoint {
        guard scale > 0 else { return center }
        func clamp(_ c: CGFloat, length: CGFloat, viewLength: CGFloat) -> CGFloat {
            let onScreen = length * scale
            let overlap = min(keptInView * onScreen, viewLength / 2)
            // The slide's leading edge in view space lies in [overlap - onScreen, viewLength - overlap].
            let lowest = overlap - onScreen
            let highest = viewLength - overlap
            let edge = viewLength / 2 - c * scale
            let kept = min(max(edge, lowest), highest)
            return (viewLength / 2 - kept) / scale
        }
        return CGPoint(
            x: clamp(center.x, length: canvas.width, viewLength: view.width),
            y: clamp(center.y, length: canvas.height, viewLength: view.height))
    }

    public mutating func fit() {
        zoom = nil
        center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    /// Sets the zoom while the slide point under `point` stays under it
    /// (unless the pan limits move it).
    public mutating func zoom(to scale: CGFloat, around point: CGPoint, in view: CGSize) {
        guard hasCanvas, view.width > 0, view.height > 0 else { return }
        let range = zoomRange(in: view)
        let target = min(max(scale, range.lowerBound), range.upperBound)
        let current = viewport(in: view)
        let anchor = current.canvasPoint(fromView: point)
        let offset = CGPoint(x: point.x - anchor.x * target, y: point.y - anchor.y * target)
        let wanted = CGPoint(
            x: (view.width / 2 - offset.x) / target,
            y: (view.height / 2 - offset.y) / target)
        zoom = target
        center = Self.clampedCenter(wanted, scale: target, canvas: canvasSize, view: view)
    }

    public mutating func zoom(by factor: CGFloat, around point: CGPoint, in view: CGSize) {
        guard factor > 0, factor.isFinite else { return }
        zoom(to: scale(in: view) * factor, around: point, in: view)
    }

    /// Moves the slide by `delta` view points (a two-finger scroll moves the
    /// content with the fingers).
    public mutating func pan(by delta: CGSize, in view: CGSize) {
        guard hasCanvas, view.width > 0, view.height > 0 else { return }
        let scale = scale(in: view)
        let current = viewport(in: view)
        let start = current.canvasPoint(fromView: CGPoint(x: view.width / 2, y: view.height / 2))
        let wanted = CGPoint(x: start.x - delta.width / scale, y: start.y - delta.height / scale)
        zoom = scale
        center = Self.clampedCenter(wanted, scale: scale, canvas: canvasSize, view: view)
    }

    /// Shows the slide point `point` at the view's center at `scale`.
    public mutating func show(_ point: CGPoint, at scale: CGFloat, in view: CGSize) {
        guard hasCanvas, view.width > 0, view.height > 0 else { return }
        let range = zoomRange(in: view)
        let target = min(max(scale, range.lowerBound), range.upperBound)
        zoom = target
        center = Self.clampedCenter(point, scale: target, canvas: canvasSize, view: view)
    }

    /// Frames a slide rectangle (a selection) in the view with `margin`
    /// points around it. A line or a point gets a sensible zoom rather than
    /// an infinite one.
    public mutating func zoom(toRect rect: CGRect, in view: CGSize, margin: CGFloat) {
        guard hasCanvas, view.width > 0, view.height > 0, !rect.isNull, !rect.isInfinite else { return }
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let scale = min(
            max(view.width - 2 * margin, 1) / width,
            max(view.height - 2 * margin, 1) / height)
        show(CGPoint(x: rect.midX, y: rect.midY), at: scale, in: view)
    }

    /// The next of `zoomSteps` above or below `scale`. A zoom within 1% of a
    /// step counts as on it, so ⌘+ from 99.5% goes to 150%, not 100%.
    public static func nextStep(from scale: CGFloat, up: Bool) -> CGFloat {
        if up {
            return zoomSteps.first { $0 > scale * 1.01 } ?? maximumZoom
        } else {
            return zoomSteps.last { $0 < scale * 0.99 } ?? minimumZoom
        }
    }

    /// ⌘+ and ⌘−: the next step, centred on `focus` (the selection's middle)
    /// or kept about the view's center.
    public mutating func step(up: Bool, focus: CGPoint?, in view: CGSize) {
        let target = Self.nextStep(from: scale(in: view), up: up)
        if let focus {
            show(focus, at: target, in: view)
        } else {
            zoom(to: target, around: CGPoint(x: view.width / 2, y: view.height / 2), in: view)
        }
    }

    /// The pixels per slide pixel to rasterise text and shapes at. The view
    /// wants `scale × backing`; past `maximumRasterDimension` (but never
    /// below what Fit already draws) the render is magnified instead. While a
    /// pinch or an animated zoom is under way, `anchor` (the scale it began
    /// at) holds the raster on rungs a factor of √2 apart, so the slide is
    /// rasterised again only every √2 of zoom rather than every frame; the
    /// end of the gesture renders it sharp at the exact scale.
    public func rasterScale(in view: CGSize, backing: CGFloat, anchor: CGFloat? = nil) -> CGFloat {
        let wanted = scale(in: view) * backing
        let longest = max(canvasSize.width, canvasSize.height, 1)
        let ceiling = max(Self.maximumRasterDimension / longest, fitScale(in: view) * backing)
        let exact = min(wanted, ceiling)
        guard let anchor, anchor > 0, exact > 0 else { return exact }
        let rung = (log(exact / anchor) / log(2.0.squareRoot()) + 1e-9).rounded(.down)
        return min(anchor * pow(2.0.squareRoot(), rung), exact)
    }

    /// A step of an animated zoom between two states, `t` from 0 to 1: the
    /// scale eased geometrically, the centre linearly. The end is `to`.
    public static func blend(from: CanvasNavigation, to: CanvasNavigation, t: CGFloat, in view: CGSize) -> CanvasNavigation {
        guard t < 1 else { return to }
        let startScale = from.scale(in: view)
        let endScale = to.scale(in: view)
        let startCenter = from.viewport(in: view).canvasPoint(fromView: CGPoint(x: view.width / 2, y: view.height / 2))
        let endCenter = to.viewport(in: view).canvasPoint(fromView: CGPoint(x: view.width / 2, y: view.height / 2))
        let progress = max(0, t)
        let scale = startScale * pow(endScale / max(startScale, 0.0001), progress)
        let center = CGPoint(
            x: startCenter.x + (endCenter.x - startCenter.x) * progress,
            y: startCenter.y + (endCenter.y - startCenter.y) * progress)
        return CanvasNavigation(canvasSize: to.canvasSize, inset: to.inset, zoom: scale, center: center)
    }
}
