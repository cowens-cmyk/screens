import Foundation
import Testing

@Suite struct InputTrailSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theRecorderRunsFromLaunch() throws {
        #expect(try source("MxUSlidesApp.swift").contains("InputTrailRecorder.shared.activate()"))
    }

    @Test func everyRunOrderSurfaceChangeSaysWhatInputCameBeforeIt() throws {
        let planner = try source("ServicePlannerView.swift")
        let note = try #require(planner.range(of: "\"runOrder.surface\","))
        let line = planner[note.upperBound...].prefix(300)
        #expect(line.contains("InputTrailRecorder.shared.cause()"))
        #expect(planner.contains("InputTrailRecorder.shared.record(\"marquee in run order\")"),
                "the marquee swallows its press before the monitor sees it")
        #expect(planner.contains(".inputRegion(\"run order\")"))
    }

    @Test func thePresentSurfaceIsNamedAndWatched() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains(".inputRegion(\"present\")"))
        #expect(surface.contains("PresentScrollWatch()"))
        let focus = try #require(surface.range(of: "\"present.focus\", detail: \"scroll"))
        #expect(surface[focus.upperBound...].prefix(200).contains("InputTrailRecorder.shared.noteFocusScroll()"),
                "a run-order jump is not an unprompted move")
        #expect(surface[focus.upperBound...].prefix(800).contains("PresentCardFrames.shared.reportLanding("),
                "every jump says which card it landed on")
    }

    @Test func aClickOnTheRowAlreadyShowingJumpsBackToIt() throws {
        let planner = try source("ServicePlannerView.swift")
        #expect(planner.contains("pressedRow: { rowPressed($0, $1, visible: visible) }"))
        let press = try #require(planner.range(of: "private func rowPressed("))
        let body = planner[press.upperBound...].prefix(900)
        #expect(body.contains("RunOrderSelection.isReselect("))
        #expect(body.contains("\"runOrder.click\""))
        #expect(body.contains("onReselect()"))

        let marquee = try source("ListMarquee.swift")
        #expect(marquee.contains("runIfClick(click, pressedAt: NSEvent.mouseLocation)"))
        #expect(marquee.contains("RunLoop.main.perform(inModes: [.default])"), "after the table's own press loop")
        #expect(!marquee.contains("coordinator.remove() }"), "row clicks count in run-only too")

        #expect(try source("AppShell.swift").contains(
            "onReselect: { if mode == .present { presentFocusScroll.reselect() } }"))
        let surface = try source("ServiceContinuousView.swift")
        let watch = try #require(surface.range(of: ".background(PlanPageReselectFollow(focusScroll: $focusScroll)"))
        #expect(surface[watch.upperBound...].prefix(200).contains("reason: \"reselect\""))
        #expect(surface.contains(".onChange(of: focusScroll.reselects) { _, _ in onReselect() }"))
    }

    @Test func aResizeOrSlidesAcrossChangeKeepsThePlace() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("let _ = PresentCardFrames.shared.show(rows)"))
        let width = try #require(surface.range(of: ".onChange(of: viewport.size.width)"))
        #expect(surface[width.upperBound...].prefix(120).contains("keepPlace(because: \"width\")"))
        let across = try #require(surface.range(of: ".onChange(of: slidesAcross)"))
        #expect(surface[across.upperBound...].prefix(120).contains("keepPlace(because: \"slides across\")"))
        let recorder = try source("InputTrailRecorder.swift")
        #expect(recorder.contains("PresentCardFrames.shared.scrollView = scrollView"))
        let moved = try #require(recorder.range(of: "    private func moved() {"))
        #expect(recorder[moved.upperBound...].prefix(80).contains("PresentCardFrames.shared.moved()"), "the place settles on every scroll")
        #expect(recorder.contains("PresentLanding.correction(for: anchor, in: self.cards, grids: self.currentGrids)"))
        #expect(recorder.contains("PresentLanding.anchor(self.cards, grids: self.currentGrids)"), "the slide at the top, not just the card")
    }

    @Test func onlyInputOnThePageHoldsOrReleasesTheLiveFollow() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("hold.follows(live: itemID)"), "a picked-away item is let go")
        #expect(surface.contains("let followed = focusScroll.honoredItemID == id\n"))
        #expect(surface.contains("if !followed { picks.pick(id) }"))
        let recorder = try source("InputTrailRecorder.swift")
        #expect(!recorder.contains("trail.age(of: \"click\""), "a click anywhere in the window")
        #expect(!recorder.contains("trail.age(of: \"key\""), "typing a stage message")
        #expect(try source("ServiceControls.swift").contains("InputTrailRecorder.shared.noteKeyboardFire()"))
    }

    @Test func regionMarkersCoverNothing() throws {
        let recorder = try source("InputTrailRecorder.swift")
        let modifier = try #require(recorder.range(of: "func inputRegion(_ name: String) -> some View {"))
        let body = recorder[modifier.upperBound...].prefix(400)
        #expect(body.contains(".frame(width: 0, height: 0)"))
        #expect(body.contains("InputRegionMarker(name: name, area: proxy.size)"))
        #expect(recorder.contains("CGRect(origin: .zero, size: area).contains(convert(windowPoint, from: nil))"))
    }

    @Test func cardsAboveTheTopChangingHeightDoNotMoveTheView() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains(".coordinateSpace(name: Self.contentSpace)"))
        let row = try #require(surface.range(of: "ForEach(rows, id: \\.presentRowIdentity) { item in"))
        let rowBody = surface[row.upperBound...].prefix(900)
        #expect(rowBody.contains("PresentCardFrames.shared.noteDoc("), "every row, not only sticky cards, reports where it sits")
        #expect(!rowBody.contains("GeometryReader"), "a row's place in the content, not a reader re-run every scroll frame")
        #expect(surface.contains("PresentCardFrames.shared.contentOrigin = origin"), "one measurement per scroll frame")
        let recorderSource = try source("InputTrailRecorder.swift")
        let apply = try #require(recorderSource.range(of: "private func applyHold() {"))
        #expect(recorderSource[apply.upperBound...].prefix(1600).contains("holdPinnedUntil = ProcessInfo.processInfo.systemUptime + 0.4"),
                "a correction pins the hold")
        let recorder = try source("InputTrailRecorder.swift")
        let moved = try #require(recorder.range(of: "    private func moved() {"))
        #expect(recorder[moved.upperBound...].prefix(120).contains("PresentCardFrames.shared.captureHold()"))
        #expect(recorder.contains("PresentHold.correction(heldTop: hold.top, nowTop: now.minY)"))
        #expect(recorder.contains("\"present.hold\""), "a hold says which card changed")
        let focus = try #require(surface.range(of: "\"present.focus\", detail: \"scroll"))
        #expect(surface[focus.upperBound...].prefix(800).contains("PresentCardFrames.shared.holdCard(target)"),
                "a run-order jump holds the card it jumped to")
    }

    @Test func theStickyHeaderTakesItsOwnHeight() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("return max(0, min(-frame.minY, proxy.size.height - headerHeight))"),
                "the header sticks within its own section")
        let sticky = try #require(surface.range(of: "StickyHeader(headerHeight: headerHeight, margin: margin) {"))
        let body = surface[sticky.upperBound...].prefix(300)
        let fixed = try #require(body.range(of: ".fixedSize(horizontal: false, vertical: true)"))
        let reader = try #require(body.range(of: ".onGeometryChange(for: CGFloat.self) { $0.size.height }"))
        #expect(fixed.lowerBound < reader.lowerBound, "measured after it is held to its own height")
    }

    /// A pick scrolls to the top of the item's section, not to its header:
    /// stuck, the header sits at the bottom of its section, and a jump up
    /// to an item landed there, a grid's height short of its top
    /// (scripts/perf/landing.sh).
    @Test func thePicksAnchorIsTheSectionsTopNotItsStickyHeader() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("Color.clear.frame(height: headerHeight).id(itemID)"))
        let header = try #require(surface.range(of: "private func cardHeader("))
        let body = surface[header.upperBound...].prefix(2600)
        #expect(!body.contains(".id(item.id)"), "the header moves when it sticks")
    }

    /// Each card measures its own header. One dictionary of header heights
    /// on the page, read by every card as it was built, re-ran every card,
    /// grid and tile whenever a header changed height, as on each pick.
    @Test func eachCardKeepsItsOwnHeaderHeight() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("private struct StickySection<Content: View, Header: View>: View"))
        #expect(surface.contains("@State private var measured: CGFloat?"))
        #expect(!surface.contains("@State private var headerHeights: [String: CGFloat]"), "a mirror, not page state")
    }
}

/// A plan-list pick must not re-run the plan page's body: each run rebuilt
/// every grid on it, and a pick ran it twice (the picks counter and the
/// shell's scroll state), stalling the main thread for 250–400 ms before the
/// page moved. Measured with apps/mac/scripts/perf/present.sh.
@Suite struct PlanPickSweepTests {
    private func page() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ServiceContinuousView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aPickLeavesThePageBodyAlone() throws {
        let page = try page()
        #expect(page.contains("@State private var picks = PresentPicks()"))
        #expect(page.contains("private final class PresentPicks"), "a reference, not page state")
        // Read in a modifier of its own: in the page's GeometryReader, each
        // pick's write to the position re-ran every card under it.
        #expect(page.contains(".modifier(PlanPageScrollPosition(pageScroll: pageScroll))"))
        #expect(page.contains("content.scrollPosition($scroll.position)"))
        #expect(!page.contains(".scrollPosition($pageScroll.position)"))
        #expect(page.contains("final class PlanPageScroll"))
        #expect(!page.contains(".onChange(of: focusScroll.reselects) {\n"), "read in PlanPageReselectFollow only")
        #expect(!page.contains("proxy.scrollTo(Self.anchor(for: target"), "a ScrollViewReader only moved when the page re-ran")
    }

    /// A glide builds the rows it lands on, one row a frame across the page,
    /// and a row coming in makes only its own tiles. Measured with Time
    /// Profiler over scripts/perf/present.sh: three or four rows made in one
    /// frame was the 20-50 ms stutter in the middle of a glide.
    @Test func aGlideBuildsWhereItLandsARowAtATime() throws {
        let page = try page()
        #expect(page.contains("PresentCardFrames.shared.beginGlide(to: target, duration: Self.jumpSeconds)"))
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PresentGridView.swift")
        let grid = try String(contentsOf: url, encoding: .utf8)
        #expect(grid.contains("if let landing = PageGlide.shared.landingTop {"))
        #expect(grid.contains("RowBuildPacer.shared.request(rowQueue)"), "one row a frame for the whole page")
        #expect(grid.contains("GridRowSwitch(flag: rowQueue.flag("), "a row reads its own flag")
        #expect(!grid.contains("@State private var builtRows"), "a set in the grid's state re-ran every built tile")
    }

    /// `@AppStorage` re-runs its view on any UserDefaults write, whatever
    /// the key; `@HotDefault` only for its own. No view holds an
    /// `@AppStorage`.
    @Test func noViewHoldsAnAppStorage() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var misses: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var owner = ""
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.hasPrefix("struct ") || line.hasPrefix("private struct ") || line.hasPrefix("fileprivate struct ") {
                    owner = String(line)
                }
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("@AppStorage("), !owner.contains("Commands") {
                    misses.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(misses.isEmpty, "use @HotDefault: \(misses)")
    }

    /// A pick must not re-run the plan list's body (every row and menu):
    /// a stored @Binding re-runs its view on every change, read or not.
    @Test func aPickLeavesThePlanListBodyAlone() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ServicePlannerView.swift")
        let list = try String(contentsOf: url, encoding: .utf8)
        #expect(list.contains("struct RunOrderList: View, Equatable {"))
        #expect(list.contains("let currentItem: RunOrderCurrentItem"))
        #expect(!list.contains("@Binding var selectedItemID: String?\n    /// The plan"), "held, not bound")
        #expect(list.contains("@State private var marks = RunOrderMarks()"))
        #expect(!list.contains("@State private var rowFrames"), "frames live in RowFrameStore")
        #expect(list.contains("RunOrderMenu { itemMenu("), "a row's menu is built when it opens")
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text of a function in `source`, from its `func` to the next
    /// member at the same indent.
    private func member(_ signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// A drop target and a right-click menu on every tile were half of what
    /// a tile cost to make. The grid has one of each and finds the tile.
    @Test func aSlideGridHasOneDropTargetAndOneMenuForAllItsTiles() throws {
        let grid = try appSource("PresentGridView.swift")
        #expect(grid.components(separatedBy: "delegate: SlideGridDropDelegate(").count == 2, "one drop target")
        #expect(!grid.contains("GutterDropDelegate("), "no drop target per tile")
        #expect(
            grid.components(separatedBy: ".contextMenu { if !runOnly { GridMenuContent(grid: self, press: menuPress) } }").count == 2,
            "one menu, built for the tile the click was over")
        for signature in [
            "private func tile(index: Int, slide: Slide, aspect: CGFloat) -> some View {",
            "private func gridTile(index: Int, slide: Slide, aspect: CGFloat) -> some View {",
        ] {
            let tile = try member(signature, in: grid)
            for perTile in [".contextMenu", ".onDrop(", ".dropDestination(", ".overlay"] {
                #expect(!tile.contains(perTile), "\(perTile) on every tile")
            }
        }
        #expect(grid.contains("GridDropMarkLayer(marks: dropMarks)"), "one layer draws the drop mark")
        #expect(!grid.contains("@State private var dropTargetIndex"), "a drag over the tiles doesn't re-run the grid")
    }

    /// With a drag source under the pointer SwiftUI takes the first click in
    /// a window that isn't active; without one the click only brings the
    /// window forward. A click on a slide has to fire with another app in
    /// front, so the drag source stays on the tile.
    @Test func aTileKeepsItsDragSourceSoAClickFiresFromBehindAnotherApp() throws {
        let grid = try appSource("PresentGridView.swift")
        let tile = try member("private func tile(index: Int, slide: Slide, aspect: CGFloat) -> some View {", in: grid)
        #expect(tile.contains(".draggablePayload(runOnly ? nil : SlideBulkEdit.slideDragPayload("))
    }

    /// SwiftUI hears of the tile a right-click named a moment later; asked
    /// for the menu before then, it gives the last one it built, for
    /// another slide. Pending work is flushed first, the menu is only built
    /// for the click that named its tile, and every other click forgets it.
    @Test func theGridsMenuIsAlwaysForTheSlideUnderTheClick() throws {
        let menu = try appSource("SlideGridMenu.swift")
        let saw = try member("func saw(_ event: NSEvent) {", in: menu)
        #expect(saw.contains("if named { CATransaction.flush() }"))
        #expect(saw.contains("press.forget()"), "every other grid, and every plain click, forgets its tile")
        let tile = try member("func tile() -> Int? {", in: menu)
        #expect(tile.contains("_ = presses"), "each right-click builds the menu again")
        #expect(tile.contains("systemUptime - pressedAt < Self.window"), "no menu without a click that named a tile")
        #expect(menu.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"), "the anchor takes no clicks")
    }

    /// A song's arrangement, kept whole beside its name, took the row's
    /// room first: "I Speak Jesus" read "I S…sus". The name has the row and
    /// the arrangement sits under it.
    @Test func aPlanRowsNameHasTheRow() throws {
        let list = try appSource("ServicePlannerView.swift")
        let row = try member("private func itemRow(", in: list)
        #expect(row.contains("            .layoutPriority(1)\n            Spacer(minLength: 4)"), "the name takes what the rest leaves")
        #expect(!row.contains(".layoutPriority(2)"), "nothing beside the name outranks it")
        let name = try #require(row.range(of: "Text(displayName(item))"))
        let under = try #require(row.range(of: "Text(override)"))
        let between = row[name.upperBound..<under.lowerBound]
        #expect(!between.contains("Spacer("), "the arrangement is under the name, in its column")
    }

    /// The side TVs are a screen of their own, off until a Mac wants them;
    /// the screens panel can turn them on, as Settings can.
    @Test func theScreensPanelCanTurnOnTheSideTVs() throws {
        let panel = try appSource("MonitorsPanel.swift")
        #expect(panel.contains("if !setup.sideTVsOn, !runOnly {\n                    Button(\"Turn On \\(ShowScreen.sideTVs.name)\") { turnOnSideTVs() }"))
        let turnOn = try member("private func turnOnSideTVs() {", in: panel)
        #expect(turnOn.contains("ShowScreens.setSideTVs(true, render: render)"))
    }

    /// Settings › Screens lists every display and DeckLink port with the
    /// screen it shows beside it, Side TVs among them, and choosing Side TVs
    /// for an output turns them on.
    @Test func everyOutputHasAShowsMenuWithEveryScreen() throws {
        let settings = try appSource("ScreensSettings.swift")
        #expect(settings.contains("OutputsSection(render: render)"))
        let section = try #require(settings.range(of: "private struct OutputsSection: View {"))
        let body = settings[section.upperBound...].prefix(4000)
        #expect(body.contains("ForEach(outputs.displays)"), "every display")
        #expect(body.contains("ForEach(ports)"), "every DeckLink port")
        #expect(body.contains("ScreenRouting.setPort(device, to: $0, render: render)"))
        #expect(body.contains("not found yet"), "a chosen port is listed before the driver reports it")
        let picker = try #require(settings.range(of: "private struct OutputShowsPicker: View {"))
        #expect(settings[picker.upperBound...].prefix(1500).contains("ForEach(ShowScreen.allCases)"), "Side TVs offered even while off")
        let screens = try appSource("ThreeScreens.swift")
        let making = try member("static func making(_ role: ShowScreen, render: RenderContext) -> ScreenOutput? {", in: screens)
        #expect(making.contains("ShowScreens.setSideTVs(true, render: render)"))
        let assign = try member("static func setPort(_ device: DeckLinkHelperDevice, to role: ShowScreen?, render: RenderContext) {", in: screens)
        #expect(assign.contains("ScreenOutput.making(role, render: render)"))
    }

    /// At launch the screens are made before NDI and DeckLink restore onto
    /// them: a port restored onto a screen not made yet is skipped, and the
    /// next save would forget it.
    @Test func screensAreMadeBeforeTheirOutputsComeBack() throws {
        let controls = try appSource("ServiceControls.swift")
        let ensure = try #require(controls.range(of: "ShowScreens.ensure(render: render)"))
        let ndi = try #require(controls.range(of: "NDIScreenOutputs.shared.restore(render: render)"))
        let deckLink = try #require(controls.range(of: "DeckLinkScreenOutputs.shared.restore(render: render)"))
        #expect(ensure.lowerBound < ndi.lowerBound && ndi.lowerBound < deckLink.lowerBound)
    }
}
