import Foundation
import Testing

/// Settings was regrouped into a sidebar of sections. Search reads
/// SettingsIndex and jumps to the row carrying the same id, so every entry
/// must be placed on a pane, every setting from before the regrouping must
/// still have an entry, and old section names must still open somewhere.
@Suite struct SettingsSweepTests {
    private static let indexFile = "SettingsIndex.swift"

    private func indexIDs(_ sweep: SourceSweep) throws -> [String] {
        let index = try #require(sweep.file(Self.indexFile)).text
        return index.matches(of: /id: "([a-zA-Z.]+)"/).map { String($0.1) }
    }

    @Test func everyIndexedSettingIsPlacedOnAPane() throws {
        let sweep = try SourceSweep.app()
        let ids = try indexIDs(sweep)
        #expect(ids.count >= 50, "SettingsIndex lists \(ids.count) settings")
        #expect(Set(ids).count == ids.count, "an id is listed twice")
        let panes = sweep.files.filter { $0.name != Self.indexFile }.map(\.text).joined(separator: "\n")
        // The three screens' sections are anchored as "screens.<role>".
        let perRole: Set<String> = ["screens.audience", "screens.livestream", "screens.stage"]
        #expect(panes.contains("settingsAnchor(\"screens.\\(role.rawValue)\")"))
        for id in ids where !perRole.contains(id) {
            let placed = ["SettingsRow(\"\(id)\"", "SettingsToggle(\"\(id)\"",
                          "SettingsHeader(id: \"\(id)\"", "settingsAnchor(\"\(id)\""]
                .contains { panes.contains($0) }
            #expect(placed, "\(id) is in search but on no pane")
        }
    }

    /// The old → new checklist: each setting the old Settings had keeps an
    /// entry (most kept their ids; the Show Setup and Screen Configuration
    /// blocks were split into the rows that replaced them).
    @Test func nothingFromTheOldSettingsWasLost() throws {
        let ids = Set(try indexIDs(try SourceSweep.app()))
        let kept = [
            "present.mediaTransition", "present.slideTransition", "present.defaultAnimations",
            "present.continuous", "present.slidesAcross", "present.roundedCorners", "present.legibleText",
            "present.transparencyGrid", "present.scopedBackgrounds", "present.nextSkipsBlanks",
            "present.layouts", "present.runOnly", "present.types",
            "avInputs.cameras", "avInputs.audio", "midi.devices", "midi.lightkey", "midi.map",
            "network.ndi", "show.typeScreens", "show.decklink", "show.liveAssist",
            "bible.sermon", "bible.themes", "bible.sources", "api.assistant",
            "anthem.link", "shepherd.sync",
            "api.enabled", "api.port", "api.address", "api.remote", "api.tokens", "api.docs",
        ]
        let split = [
            // show.screens (Show Setup's screens, livestream switch, stage messages)
            "screens.audience", "screens.livestream", "screens.stage", "screens.alphaKey",
            "show.streamMode", "show.stageMessages",
            // screens.configuration (the Screen Configuration window)
            "screens.arrangement", "screens.ndi",
        ]
        for id in kept + split {
            #expect(ids.contains(id), "\(id) has no place in Settings")
        }
    }

    @Test func oldSectionNamesStillOpenASection() throws {
        let view = try #require(try SourceSweep.app().file("SettingsView.swift")).text
        let start = try #require(view.range(of: "init?(storedID: String) {"))
        let body = view[start.upperBound...].prefix(600)
        for old in ["showSetup", "present", "appearance", "avInputs", "midi", "shepherd", "api"] {
            #expect(body.contains("\"\(old)\""), "a shortcut saved for \(old) would open nothing")
        }
        let keys = try #require(try SourceSweep.app().file("KeyboardShortcuts.swift")).text
        #expect(keys.contains("SettingsCategory(storedID: id)"))
    }

    /// Keys are read from the Keychain only when someone opens the page that
    /// shows them (ClaudeKeyField reads on appear), never by Settings' own
    /// code, which SwiftUI builds before anyone looks.
    @Test func settingsCodeNeverReadsTheKeychain() throws {
        let sweep = try SourceSweep.app()
        for name in ["SettingsView.swift", "SettingsPanes.swift", "SettingsIndex.swift", "ScreensSettings.swift",
                     "ShowSetupSettings.swift"] {
            let code = try #require(sweep.file(name), "\(name) missing").codeLines.joined(separator: "\n")
            for read in ["SecretStore.load", "ClaudeClient.apiKey", "Keychain.load"] {
                #expect(!code.contains(read), "\(name) reads the Keychain (\(read))")
            }
        }
    }

    /// The Screen Configuration window's entry points (Window menu, More ›
    /// Screen Setup…) open Settings › Screens.
    @Test func screenConfigurationOpensSettingsScreens() throws {
        let screens = try #require(try SourceSweep.app().file("ThreeScreens.swift")).text
        #expect(screens.contains("SettingsRouter.shared.open(.screens)"))
        #expect(screens.contains("dismissWindow(id: \"outputs\")"))
    }
}
