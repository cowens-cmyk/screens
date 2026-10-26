import Foundation
import Testing

@Suite struct EditorSelectionSweepTests {
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

    @Test func sceneAndInteractionSpanThePasteboard() throws {
        let editor = try source("SlideEditorView.swift")
        let scene = try #require(editor.range(of: """
            SceneCanvas(
                                    render: render, transparentBackground: true, inset: EditorGeometry.pasteboardInset,
                                    navigator: model.canvasNavigator)

            """))
        let next = editor[scene.upperBound...].prefix(120)
        #expect(next.contains("EditorInteractionView(model: model)\n"), "the interaction view sits right over the scene")
        #expect(!next.contains(".aspectRatio("), "neither is cut to the slide's aspect")
        #expect(editor.contains("CanvasCheckerboard(navigator: model.canvasNavigator)"),
                "the checkerboard stays the slide's size, at the canvas's zoom")

        let canvas = try source("EditorInteractionView.swift")
        #expect(canvas.contains("drawPasteboardVeil(in: context)\n        drawGuides("), "the veil draws under all chrome")
        #expect(canvas.contains("model.canvasNavigator.viewport(in: bounds.size)"))
        #expect(editor.contains("navigator.canvasPoint(fromView: location, in: canvasViewSize)"),
                "drops map through the same viewport")
        #expect(editor.components(separatedBy: "CanvasPlaced(navigator: model.canvasNavigator)").count == 3,
                "the Animate overlay and the drop outline sit on the same slide rectangle")
        #expect(!editor.contains(".padding(EditorGeometry.pasteboardInset)"),
                "nothing letterboxes itself apart from the canvas's zoom")
    }

    /// Every slide editor (slides, themes, overlays, stage layouts) is this
    /// one canvas, so zoom, pan and the zoom keys behave the same in each.
    @Test func everyEditorSharesOneNavigableCanvas() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(try source("AppShell.swift").contains("SlideEditorView("))
        #expect(try source("PlanShell.swift").contains("SlideEditorView("))
        #expect(editor.contains("CanvasZoomControl(model: model, viewSize: canvasViewSize)"))
        #expect(editor.contains(".keyboardShortcut(\"0\", modifiers: .command)"))
        #expect(editor.contains(".keyboardShortcut(\"0\", modifiers: [.command, .option])"))

        let navigator = try source("CanvasNavigator.swift")
        #expect(navigator.contains("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion"), "Reduce Motion jumps")
        #expect(try source("EditorInteractionView.swift").contains("return self.window?.firstResponder === self"),
                "Space and the zoom keys only with the canvas focused")
        #expect(navigator.contains("guard mods.contains(.command), !mods.contains(.control)"),
                "⌃⌘0 stays Reset Sermon Timer")
    }

    @Test func aPressKeepsTheSelectedObjectUnderAnother() throws {
        let canvas = try source("EditorInteractionView.swift")
        #expect(canvas.contains("EditorGeometry.pressTarget(\n                at: point, in: objects, selected: model.selectedObjectIDs"))
        #expect(canvas.contains("if event.clickCount == 2, let hit = pressed, model.canEditPath(hit)"), "double-click edits the pressed object")
        #expect(canvas.contains("if event.clickCount == 2, let hit = pressed,\n"))
        #expect(canvas.contains(": pressed\n"), "a plain press moves the pressed object")
    }

    @Test func objectsPanelTakesModifierClicksAndBothListsSweep() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(!editor.contains("select: { model.setSelection([entry.object.id]) }"),
                "a select-on-down with ⌘/⇧ held undid the List's own extend")
        let objectSelect = try #require(editor.range(of: "if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) {\n"
            + "                                                model.setSelection([entry.object.id])"))
        #expect(!objectSelect.isEmpty, "only a plain press selects on the way down")
        #expect(editor.contains(".reportingGlobalFrame(id: slide.id, into: $slideRowFrames)"))
        #expect(editor.contains(".reportingGlobalFrame(id: entry.object.id, into: $objectRowFrames)"))
        #expect(editor.contains("rowFrames: Array(slideRowFrames.values)"))
        #expect(editor.contains("rowFrames: Array(objectRowFrames.values)"))
        #expect(editor.contains("RunOrderSelection.swept(frames: slideRowFrames, band: band, keeping: slideMarqueeBase)"))
        #expect(editor.contains("RunOrderSelection.swept(frames: objectRowFrames, band: band, keeping: objectMarqueeBase)"))
        #expect(editor.contains(".overlay { ListMarqueeBand(rect: slideMarquee) }"))
        #expect(editor.contains(".overlay { ListMarqueeBand(rect: objectMarquee) }"))
    }
}
