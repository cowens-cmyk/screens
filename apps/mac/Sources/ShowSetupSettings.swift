import PresenterCore
import SwiftUI

/// Settings › Show Setup: which screen is the audience, the livestream and
/// the stage display, how the livestream behaves, and Live Assist.
struct ShowSetupForm: View {
    let controls: ServiceControls
    @Bindable private var setup = ShowSetup.shared
    @Bindable private var assist = LiveAssist.shared

    private var screens: [(id: String, name: String)] { PreviewTargets.screens(controls.render) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screenPicker("Audience screen", $setup.audienceTarget)
            screenPicker("Livestream screen", $setup.streamTarget)
            screenPicker("Stage display", $setup.stageTarget)
            Text("Screens are created and assigned to displays, NDI or DeckLink in Screen Configuration. For a keyed livestream, assign it to the DeckLink output with Alpha Key on.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Livestream", selection: $setup.streamMode) {
                ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Auto: a slide whose theme has a livestream lower third (set in the theme editor) shows in it; everything else leaves the camera clear. Full Screen: the room's slide, edge to edge. Off: nothing over the camera.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func screenPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(screens, id: \.id) { Text($0.name).tag($0.id) }
        }
    }
}

struct LiveAssistSettingsForm: View {
    @Bindable private var assist = LiveAssist.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveAssistInputPicker()
            Toggle("Advance lyrics as they're sung", isOn: $assist.followsLyrics)
            Slider(value: $assist.autoAdvanceConfidence, in: 0.5...0.95) {
                Text("Advance when \(Int(assist.autoAdvanceConfidence * 100))% sure")
            }
            Toggle("Watch for spoken Bible references", isOn: $assist.detectsScripture)
            Text("Start and stop listening, watch the confidence meter and show detected passages in Window › Live Assist (⌥⌘L).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScriptureThemeSetting: View {
    let model: AppModel

    var body: some View {
        Picker("Default scripture theme", selection: model.slideBuildingBinding(\.scriptureThemeId)) {
            Text("The presentation's own theme").tag("")
            ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
        }
        Picker("Default points theme", selection: model.slideBuildingBinding(\.pointsThemeId)) {
            Text("The presentation's own theme").tag("")
            ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
        }
    }
}
