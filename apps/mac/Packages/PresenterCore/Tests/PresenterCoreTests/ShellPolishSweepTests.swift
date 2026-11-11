import Foundation
import Testing

/// Reads the app's sources for menu, Settings and tooltip rules that were
/// each broken once: clears that did nothing from some windows, an update
/// a Simple Mode volunteer could start mid-service, a screen dropped over
/// the operator's own display, and tooltips naming keys that were rebound.
@Suite struct ShellPolishSweepTests {
    private func text(_ name: String) throws -> String {
        try #require(try SourceSweep.app().file(name)).text
    }

    /// Lines that aren't comments, so a comment quoting an old string
    /// doesn't count.
    private func code(_ file: SourceSweep.File) -> [(Int, String)] {
        file.lines.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.map { ($0.offset + 1, $0.element) }
    }

    /// Live Assist, Media Library and Settings publish no focused
    /// ServiceControls; the Present menu falls back to the app's own, so
    /// F1 still clears with one of them in front.
    @Test func presentMenuClearsFromAnyWindow() throws {
        let commands = try text("PresentCommands.swift")
        #expect(commands.contains("focusedControls ?? fallback"))
        #expect(!commands.contains("@FocusedValue(\\.serviceControls) private var controls"))
        #expect(try text("MxUSlidesApp.swift").contains("PresentCommands(fallback: controls)"))
        // Every clear is disabled when there is nothing to clear with, as
        // Black Screen is, rather than looking usable and doing nothing.
        let buttons = commands.components(separatedBy: "Button(\"Clear ").count - 1
        let disabled = commands.components(separatedBy: ".disabled(controls == nil").count - 1
        #expect(buttons >= 5)
        #expect(disabled >= buttons, "\(buttons) clear buttons, \(disabled) disabled when controls is nil")
    }

    /// Updating quits without the quit prompt, and the sermon timer reset
    /// is a per-Mac setting: Simple Mode locks both.
    @Test func simpleModeLocksUpdatingAndTheTimerSetting() throws {
        let app = try text("MxUSlidesApp.swift")
        let start = try #require(app.range(of: "struct UpdateCommands"))
        let end = try #require(app.range(of: "struct MxUSlidesApp"))
        let updates = String(app[start.lowerBound ..< end.lowerBound])
        #expect(updates.contains("@AppStorage(PresentLayoutController.lockedKey)"))
        #expect(updates.contains(".disabled(runOnly)"))
        #expect(!app[end.lowerBound...].contains("AppUpdater.shared.check"), "the update item lives in UpdateCommands")
        #expect(try text("PresentCommands.swift").contains(".disabled(controls == nil || runOnly)"))
    }

    /// Every way Settings › Screens puts a screen on a display goes
    /// through the check that asks before covering the main display.
    @Test func screensOnTheMainDisplayAsk() throws {
        let file = try #require(try SourceSweep.app().file("ScreensSettings.swift"))
        var misses: [String] = []
        for (number, line) in code(file) {
            if line.contains("ScreenRouting.assign("), !line.contains("to: nil") {
                misses.append("\(number): \(line.trimmingCharacters(in: .whitespaces))")
            }
            if line.contains("set: output.choose)") || line.contains("output.setMirror($0") {
                misses.append("\(number): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(misses.isEmpty, "assign through ScreenRouting.assignAsking / askingAboutMain:\n\(misses.joined(separator: "\n"))")
        #expect(file.text.contains("display.isMain"))
        #expect(file.text.contains("QuitConfirmation.ask("))
    }

    /// Asking always answers; only an automatic check stays quiet.
    @Test func askingForUpdatesAlwaysAnswers() throws {
        let updater = try text("AppUpdater.swift")
        #expect(updater.contains("else if userInitiated { reportCheck() }"))
        let advanced = try text("SettingsPanes.swift")
        #expect(advanced.contains("Button(\"Install \\(release.version)…\")"))
        #expect(advanced.contains("updater.isInstalling ? \"Downloading…\""))
    }

    /// A stored 0 s is a cut, as RenderContext reads it, and stepping is
    /// rounded so drift never reaches the label.
    @Test func transitionDurationsKeepZeroAndRound() throws {
        let sweep = try SourceSweep.app()
        for name in ["SettingsView.swift", "TransitionChip.swift"] {
            let source = try #require(sweep.file(name)).text
            #expect(!source.contains("double(forKey: durationKey)"), "\(name) treats 0 as missing")
            #expect(source.contains("TransitionDuration.load(durationKey"), "\(name)")
            #expect(source.contains("duration = TransitionDuration.rounded(v)"), "\(name)")
        }
    }

    /// Shortcuts Settings › Keyboard can rebind are named from the key map,
    /// not written into the help text.
    @Test func rebindableShortcutsAreNotHardCoded() throws {
        let sweep = try SourceSweep.app()
        let written = ["(⌃⌘S)", "(⌃⌘R)", "(⌘1)", "(⌘2)", "(⌃⌘0)", "(→ or Space)", "(←)"]
        var misses: [String] = []
        for file in sweep.files {
            for (number, line) in code(file) where written.contains(where: line.contains) {
                misses.append("\(file.name):\(number) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(misses.isEmpty, "use KeyMapStore.shared.map.helpKeys(for:):\n\(misses.joined(separator: "\n"))")
        #expect(!(try text("SettingsView.swift")).contains("\"Run-Only Layout\""))
    }
}
