import Foundation
import Testing

/// Reads the app's sources for rules that keep a service running: an
/// update never interrupts it, and keys meant for the show stay with it.
@Suite struct UpdaterAndKeysSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func onlyAskingForAnUpdatePutsUpTheAlert() throws {
        let updater = try source("AppUpdater.swift")
        let calls = updater.components(separatedBy: "promptToInstall()").count - 1
        #expect(calls == 2, "the definition and one call")
        #expect(updater.contains("if userInitiated, available != nil { promptToInstall() }"))
        // Return picks Later, not Update and Relaunch.
        let later = try #require(updater.range(of: "addButton(withTitle: \"Later\")"))
        let update = try #require(updater.range(of: "addButton(withTitle: \"Update and Relaunch\")"))
        #expect(later.lowerBound < update.lowerBound)
    }

    @Test func clearsOnTypingKeysGoThroughTheMonitor() throws {
        let keys = try source("KeyboardShortcuts.swift")
        #expect(keys.contains(".clearAll, .clearSlides, .clearMedia, .clearAlerts,"))
        #expect(keys.contains("!(command.scope == .present && chord.typesInTextFields)"))
        #expect(keys.contains("KeyMapStore.shared.records(from: event.window)"))
    }
}
