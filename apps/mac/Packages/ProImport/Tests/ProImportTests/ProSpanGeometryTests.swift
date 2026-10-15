import Foundation
import Testing
@testable import ProImport

/// Multi-screen span geometry reached through `mapScreens`: the canvas is the
/// union of the output bounds, and each output becomes a unit-rect slice of it.
struct ProSpanGeometryTests {

    private func uuid(_ string: String) -> RVData_UUID {
        var id = RVData_UUID()
        id.string = string
        return id
    }

    private func output(
        _ id: String = "", name: String = "",
        x: Double = 0, y: Double = 0, width: Double = 1920, height: Double = 1080
    ) -> RVData_Screen {
        var out = RVData_Screen()
        out.uuid = uuid(id)
        out.name = name
        out.bounds.origin.x = x
        out.bounds.origin.y = y
        out.bounds.size.width = width
        out.bounds.size.height = height
        return out
    }

    private func edge(
        _ id: String, _ edge: RVData_EdgeBlend.Screen.Edge, radius: Double,
        gamma: Double = 0, mode: RVData_EdgeBlend.Mode = .linear,
        intensity: Double = 0, blackLevel: Double = 0
    ) -> RVData_EdgeBlend.Screen {
        var entry = RVData_EdgeBlend.Screen()
        entry.uuid = uuid(id)
        entry.edge = edge
        entry.radius = radius
        entry.gamma = gamma
        entry.mode = mode
        entry.intensity = intensity
        entry.blackLevel = blackLevel
        return entry
    }

    private func mapCombined(_ outputs: [RVData_Screen]) -> ProScreenPlan.Screen {
        var screen = RVData_ProPresenterScreen()
        screen.uuid = uuid("S")
        screen.name = "Span"
        var grid = RVData_ProPresenterScreen.CombinedArrangement()
        grid.screens = outputs
        screen.arrangement = .arrangementCombined(grid)
        var workspace = RVData_ProPresenterWorkspace()
        workspace.proScreens = [screen]
        return ProWorkspaceMapper.mapScreens(workspace).plan.screens[0]
    }

    private func mapBlend(
        _ outputs: [RVData_Screen], _ pairs: [RVData_EdgeBlend]
    ) -> ProScreenPlan.Screen {
        var screen = RVData_ProPresenterScreen()
        screen.uuid = uuid("S")
        screen.name = "Span"
        var blend = RVData_ProPresenterScreen.EdgeBlendArrangement()
        blend.screens = outputs
        blend.edgeBlends = pairs
        screen.arrangement = .arrangementEdgeBlend(blend)
        var workspace = RVData_ProPresenterWorkspace()
        workspace.proScreens = [screen]
        return ProWorkspaceMapper.mapScreens(workspace).plan.screens[0]
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func gridCanvasIsTheUnionAndSlicesAreRelativeToItsOrigin() {
        // A 2x2 grid that does not start at 0,0: the slices must be offset by
        // the union's own origin, not the global one.
        let screen = mapCombined([
            output("A", x: 1000, y: 500, width: 1000, height: 500),
            output("B", x: 2000, y: 500, width: 1000, height: 500),
            output("C", x: 1000, y: 1000, width: 1000, height: 500),
            output("D", x: 2000, y: 1000, width: 1000, height: 500),
        ])
        #expect(screen.width == 2000)
        #expect(screen.height == 1000)
        #expect(screen.slices.count == 4)
        let expected: [(Double, Double)] = [(0, 0), (0.5, 0), (0, 0.5), (0.5, 0.5)]
        for (slice, want) in zip(screen.slices, expected) {
            #expect(near(slice.x, want.0) && near(slice.y, want.1))
            #expect(near(slice.width, 0.5) && near(slice.height, 0.5))
        }
    }

    @Test func unequalOutputsAreSizedAgainstTheUnion() {
        let screen = mapCombined([
            output("A", x: 0, y: 0, width: 1920, height: 1080),
            output("B", x: 1920, y: 0, width: 1280, height: 720),
        ])
        #expect(screen.width == 3200)
        #expect(screen.height == 1080)
        #expect(near(screen.slices[1].x, 1920.0 / 3200))
        #expect(near(screen.slices[1].width, 1280.0 / 3200))
        #expect(near(screen.slices[1].height, 720.0 / 1080))
    }

    @Test func subscreenUnitRectWinsOverBounds() {
        var a = output("A", x: 0, width: 1920)
        a.subscreenUnitRect.origin.x = 0.1
        a.subscreenUnitRect.origin.y = 0.2
        a.subscreenUnitRect.size.width = 0.3
        a.subscreenUnitRect.size.height = 0.4
        let screen = mapCombined([a, output("B", x: 1920)])
        #expect(near(screen.slices[0].x, 0.1) && near(screen.slices[0].y, 0.2))
        #expect(near(screen.slices[0].width, 0.3) && near(screen.slices[0].height, 0.4))
        #expect(near(screen.slices[1].x, 0.5))
    }

    @Test func outputsWithoutBoundsFillTheCanvasAndKeepDefaults() {
        var bare = RVData_Screen()
        bare.uuid = uuid("BARE")
        let screen = mapCombined([output("A", name: "Left", width: 1280, height: 720), bare])
        #expect(screen.width == 1280 && screen.height == 720)
        #expect(screen.slices[0].name == "Left")
        #expect(screen.slices[1].name == "Output 2")
        #expect(screen.slices[1].proUUID == "bare")
        #expect(near(screen.slices[1].x, 0) && near(screen.slices[1].y, 0))
        #expect(near(screen.slices[1].width, 1) && near(screen.slices[1].height, 1))
    }

    @Test func noBoundsAnywhereKeepsTheDefaultCanvas() {
        let screen = mapCombined([RVData_Screen(), RVData_Screen()])
        #expect(screen.width == 1920 && screen.height == 1080)
        #expect(screen.slices.count == 2)
        #expect(near(screen.slices[0].width, 1))
    }

    @Test func verticalBlendsMeasureRadiusAgainstSliceHeight() {
        // Stacked outputs on a 1920x2160 canvas: a 108 px ramp is 0.1 of a
        // 1080 px slice, not 108/2160 and not a width-based value.
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("TOP", .bottom, radius: 108, mode: .quadratic)
        pair.secondScreen = edge("BOT", .top, radius: 108, mode: .linear)
        let screen = mapBlend([
            output("TOP", y: 0), output("BOT", y: 1080),
        ], [pair])
        #expect(screen.height == 2160)
        let top = screen.slices[0], bottom = screen.slices[1]
        #expect(near(top.blendBottom?.width ?? 0, 0.1))
        #expect(near(top.blendBottom?.curve ?? 0, 2))
        #expect(top.blendTop == nil && top.blendLeft == nil && top.blendRight == nil)
        #expect(near(bottom.blendTop?.width ?? 0, 0.1))
        #expect(near(bottom.blendTop?.curve ?? 0, 1))
        #expect(bottom.blendBottom == nil)
    }

    @Test func horizontalRadiusUsesSliceWidthAndSmallRadiusIsAlreadyAFraction() {
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("L", .right, radius: 192)
        pair.secondScreen = edge("R", .left, radius: 0.25)
        let screen = mapBlend([output("L", x: 0), output("R", x: 1920)], [pair])
        #expect(near(screen.slices[0].blendRight?.width ?? 0, 0.1))
        #expect(near(screen.slices[1].blendLeft?.width ?? 0, 0.25))
    }

    @Test func blendCurveFallsBackToTheModeAndThenToGamma22() {
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("L", .right, radius: 96, mode: .cubic)
        pair.secondScreen = edge("R", .left, radius: 96, gamma: 1.7, mode: .cubic)
        var other = RVData_EdgeBlend()
        other.firstScreen = edge("R", .right, radius: 96, mode: .UNRECOGNIZED(99))
        let screen = mapBlend(
            [output("L", x: 0), output("R", x: 1920)], [pair, other])
        #expect(near(screen.slices[0].blendRight?.curve ?? 0, 3))
        #expect(near(screen.slices[1].blendLeft?.curve ?? 0, 1.7))
        #expect(near(screen.slices[1].blendRight?.curve ?? 0, 2.2))
    }

    @Test func blendIntensityAndLiftAreNormalised() {
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("L", .right, radius: 96, intensity: 1, blackLevel: 2)
        pair.secondScreen = edge("R", .left, radius: 96, intensity: 0.5, blackLevel: -1)
        let screen = mapBlend([output("L", x: 0), output("R", x: 1920)], [pair])
        #expect(screen.slices[0].blendRight?.intensity == nil, "full intensity is the default")
        #expect(near(screen.slices[0].blendRight?.blackLift ?? 0, 1), "lift clamps to 1")
        #expect(near(screen.slices[1].blendLeft?.intensity ?? 0, 0.5))
        #expect(screen.slices[1].blendLeft?.blackLift == nil, "negative lift is none")
    }

    @Test func unknownEdgesAndZeroRadiusAreIgnored() {
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("L", .unknown, radius: 96)
        pair.secondScreen = edge("R", .left, radius: 0)
        let screen = mapBlend([output("L", x: 0), output("R", x: 1920)], [pair])
        for slice in screen.slices {
            #expect(slice.blendLeft == nil && slice.blendRight == nil)
            #expect(slice.blendTop == nil && slice.blendBottom == nil)
        }
    }

    @Test func blendWidthIsCappedAtTheWholeSlice() {
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge("L", .right, radius: 5000)
        let screen = mapBlend([output("L", x: 0), output("R", x: 1920)], [pair])
        #expect(near(screen.slices[0].blendRight?.width ?? 0, 1))
    }

    @Test func blendEntriesMatchOutputsByCaseInsensitiveUUID() {
        var pair = RVData_EdgeBlend()
        pair.leftScreen = edge("abc-1", .right, radius: 96)
        pair.rightScreen = edge("ABC-2", .left, radius: 96)
        let screen = mapBlend([output("ABC-1", x: 0), output("abc-2", x: 1920)], [pair])
        #expect(screen.slices[0].blendRight != nil)
        #expect(screen.slices[1].blendLeft != nil)
    }
}
