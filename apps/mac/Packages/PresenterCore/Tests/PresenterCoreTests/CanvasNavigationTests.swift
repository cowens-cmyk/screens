import CoreGraphics
import Foundation
import Testing
@testable import PresenterCore

struct CanvasNavigationTests {
    private let slide = CGSize(width: 1920, height: 1080)
    private let view = CGSize(width: 1000, height: 700)

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool { abs(a - b) <= tolerance }
    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool {
        close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance)
    }

    @Test func fitLetterboxesInsideTheInset() {
        let nav = CanvasNavigation(canvasSize: slide, inset: 32)
        #expect(nav.isFit)
        let viewport = nav.viewport(in: view)
        #expect(close(viewport.scale, (1000 - 64) / 1920.0), "width-limited")
        #expect(close(viewport.offset.x, 32))
        #expect(close(viewport.offset.y, (700 - 1080 * viewport.scale) / 2))
        // The slide's middle is the view's middle.
        #expect(close(viewport.viewPoint(fromCanvas: CGPoint(x: 960, y: 540)), CGPoint(x: 500, y: 350)))
    }

    @Test func viewportConversionsRoundTrip() {
        let viewport = CanvasViewport(scale: 2.5, offset: CGPoint(x: -300, y: 41))
        let point = CGPoint(x: 123.25, y: 987.5)
        #expect(close(viewport.canvasPoint(fromView: viewport.viewPoint(fromCanvas: point)), point))
        let rect = CGRect(x: 10, y: 20, width: 300, height: 40)
        let there = viewport.viewRect(fromCanvas: rect)
        #expect(close(there.width, 750))
        let back = viewport.canvasRect(fromView: there)
        #expect(close(back.origin, rect.origin) && close(back.width, rect.width) && close(back.height, rect.height))
    }

    @Test func zoomAroundAPointKeepsItFixed() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        let pointer = CGPoint(x: 640, y: 300)
        let under = nav.viewport(in: view).canvasPoint(fromView: pointer)
        nav.zoom(to: 1.5, around: pointer, in: view)
        #expect(!nav.isFit)
        #expect(close(nav.scale(in: view), 1.5))
        #expect(close(nav.viewport(in: view).viewPoint(fromCanvas: under), pointer, 1e-4))

        // And again, by a factor, as a pinch does.
        let second = CGPoint(x: 200, y: 600)
        let underSecond = nav.viewport(in: view).canvasPoint(fromView: second)
        nav.zoom(by: 1.25, around: second, in: view)
        #expect(close(nav.scale(in: view), 1.875))
        #expect(close(nav.viewport(in: view).viewPoint(fromCanvas: underSecond), second, 1e-4))
    }

    @Test func zoomIsClampedToTenToEightHundredPercent() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        nav.zoom(to: 50, around: .zero, in: view)
        #expect(nav.scale(in: view) == CanvasNavigation.maximumZoom)
        nav.zoom(to: 0.001, around: .zero, in: view)
        #expect(nav.scale(in: view) == CanvasNavigation.minimumZoom)

        // A window too small for 10% still fits.
        let tiny = CGSize(width: 150, height: 120)
        let fit = nav.fitScale(in: tiny)
        #expect(fit < CanvasNavigation.minimumZoom)
        nav.zoom(to: 0.001, around: .zero, in: tiny)
        #expect(close(nav.scale(in: tiny), fit))
    }

    @Test func panningKeepsAFifthOfTheSlideInView() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        nav.zoom(to: 0.25, around: CGPoint(x: 500, y: 350), in: view)
        // 480 × 270 points on screen; fling it far off to the right and down.
        nav.pan(by: CGSize(width: 5000, height: 5000), in: view)
        var onScreen = nav.viewport(in: view).viewRect(fromCanvas: CGRect(origin: .zero, size: slide))
        #expect(close(view.width - onScreen.minX, 0.2 * 480, 1e-4))
        #expect(close(view.height - onScreen.minY, 0.2 * 270, 1e-4))
        nav.pan(by: CGSize(width: -10000, height: -10000), in: view)
        onScreen = nav.viewport(in: view).viewRect(fromCanvas: CGRect(origin: .zero, size: slide))
        #expect(close(onScreen.maxX, 0.2 * 480, 1e-4))
        #expect(close(onScreen.maxY, 0.2 * 270, 1e-4))

        // Zoomed far in, the slide's edge may come to the view's middle and
        // no further, so the pasteboard past it stays reachable.
        nav.zoom(to: 8, around: CGPoint(x: 500, y: 350), in: view)
        nav.pan(by: CGSize(width: 100_000, height: 0), in: view)
        onScreen = nav.viewport(in: view).viewRect(fromCanvas: CGRect(origin: .zero, size: slide))
        #expect(close(onScreen.minX, view.width / 2, 1e-4))
    }

    @Test func panMovesTheContentWithTheFingers() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        nav.zoom(to: 1, around: CGPoint(x: 500, y: 350), in: view)
        let before = nav.viewport(in: view).offset
        nav.pan(by: CGSize(width: 40, height: -25), in: view)
        let after = nav.viewport(in: view).offset
        #expect(close(after.x - before.x, 40, 1e-6))
        #expect(close(after.y - before.y, -25, 1e-6))
    }

    @Test func actualSizeIsOneSlidePixelPerPoint() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        nav.zoom(to: 1, around: CGPoint(x: 500, y: 350), in: view)
        let viewport = nav.viewport(in: view)
        let width = viewport.viewRect(fromCanvas: CGRect(origin: .zero, size: slide)).width
        #expect(close(width, 1920))
        nav.fit()
        #expect(nav.isFit)
        #expect(nav.viewport(in: view) == CanvasNavigation(canvasSize: slide, inset: 32).viewport(in: view))
    }

    @Test func zoomToRectFramesItInTheMiddle() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        let selection = CGRect(x: 1500, y: 800, width: 200, height: 100)
        nav.zoom(toRect: selection, in: view, margin: 40)
        let viewport = nav.viewport(in: view)
        #expect(close(viewport.scale, min((1000 - 80) / 200.0, (700 - 80) / 100.0)))
        let framed = viewport.viewRect(fromCanvas: selection)
        #expect(close(CGPoint(x: framed.midX, y: framed.midY), CGPoint(x: 500, y: 350), 1e-4))

        // A hairline doesn't zoom to infinity.
        nav.zoom(toRect: CGRect(x: 100, y: 100, width: 0, height: 0), in: view, margin: 40)
        #expect(nav.scale(in: view) == CanvasNavigation.maximumZoom)
    }

    @Test func stepsWalkTheLadder() {
        #expect(CanvasNavigation.nextStep(from: 0.487, up: true) == 0.5)
        #expect(CanvasNavigation.nextStep(from: 0.995, up: true) == 1.5, "on a step already")
        #expect(CanvasNavigation.nextStep(from: 1, up: false) == 0.67)
        #expect(CanvasNavigation.nextStep(from: 8, up: true) == 8)
        #expect(CanvasNavigation.nextStep(from: 0.1, up: false) == 0.1)

        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        let focus = CGPoint(x: 300, y: 200)
        nav.step(up: true, focus: focus, in: view)
        #expect(nav.scale(in: view) == 0.5)
        let shown = nav.viewport(in: view).viewPoint(fromCanvas: focus)
        #expect(close(shown, CGPoint(x: 500, y: 350), 1e-4), "centred on the selection")
    }

    @Test func fitFollowsTheViewAndZoomKeepsTheCentre() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        let wider = CGSize(width: 1400, height: 900)
        #expect(nav.viewport(in: wider).scale == nav.fitScale(in: wider))

        nav.zoom(to: 2, around: CGPoint(x: 700, y: 200), in: view)
        let middle = nav.viewport(in: view).canvasPoint(fromView: CGPoint(x: 500, y: 350))
        let resized = nav.viewport(in: wider)
        #expect(resized.scale == 2)
        #expect(close(resized.viewPoint(fromCanvas: middle), CGPoint(x: 700, y: 450), 1e-4))
    }

    @Test func rasterScaleIsCappedAndHeldOnRungsWhileZooming() {
        var nav = CanvasNavigation(canvasSize: slide, inset: 32)
        let fitPixels = nav.fitScale(in: view) * 2
        #expect(close(nav.rasterScale(in: view, backing: 2), fitPixels), "Fit renders at the view's pixels")

        nav.zoom(to: 1, around: .zero, in: view)
        #expect(close(nav.rasterScale(in: view, backing: 2), 2), "100% on Retina: two pixels per slide pixel")
        nav.zoom(to: 8, around: .zero, in: view)
        #expect(close(nav.rasterScale(in: view, backing: 2), 4096 / 1920.0), "800% magnifies a capped render")

        // A wide 5K editor already draws Fit past the cap; zooming never draws softer than that.
        let huge = CGSize(width: 2600, height: 1500)
        var wide = CanvasNavigation(canvasSize: slide, inset: 32)
        let hugeFit = wide.fitScale(in: huge) * 2
        #expect(hugeFit > 4096 / 1920.0)
        wide.zoom(to: 8, around: .zero, in: huge)
        #expect(close(wide.rasterScale(in: huge, backing: 2), hugeFit))

        // Mid-pinch, rungs √2 apart from where the pinch began.
        var pinch = CanvasNavigation(canvasSize: slide, inset: 32)
        pinch.zoom(to: 0.5, around: .zero, in: view)
        let anchor = pinch.rasterScale(in: view, backing: 2)
        #expect(close(anchor, 1))
        pinch.zoom(to: 0.6, around: .zero, in: view)
        #expect(close(pinch.rasterScale(in: view, backing: 2, anchor: anchor), 1), "no new raster yet")
        pinch.zoom(to: 0.75, around: .zero, in: view)
        #expect(close(pinch.rasterScale(in: view, backing: 2, anchor: anchor), 2.0.squareRoot()))
        pinch.zoom(to: 0.4, around: .zero, in: view)
        #expect(close(pinch.rasterScale(in: view, backing: 2, anchor: anchor), 1 / 2.0.squareRoot()))
        #expect(close(pinch.rasterScale(in: view, backing: 2), 0.8), "sharp again when it ends")
    }

    @Test func blendEndsExactlyOnTheTarget() {
        let start = CanvasNavigation(canvasSize: slide, inset: 32)
        var end = start
        end.zoom(to: 2, around: CGPoint(x: 100, y: 100), in: view)
        #expect(CanvasNavigation.blend(from: start, to: end, t: 1, in: view) == end)
        let first = CanvasNavigation.blend(from: start, to: end, t: 0, in: view)
        #expect(close(first.scale(in: view), start.scale(in: view)))
        let half = CanvasNavigation.blend(from: start, to: end, t: 0.5, in: view)
        #expect(close(half.scale(in: view), (start.scale(in: view) * 2).squareRoot(), 1e-6))
        #expect(CanvasNavigation.blend(from: end, to: start, t: 1, in: view).isFit)
    }
}
