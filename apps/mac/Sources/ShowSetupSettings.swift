import PresenterCore
import SwiftUI

/// Settings › Show Setup: the Audience, Livestream and Stage screens and
/// how the livestream behaves.
struct ShowSetupForm: View {
    let controls: ServiceControls
    @Bindable private var setup = ShowSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThreeScreensView(render: controls.render)
            Picker("Livestream", selection: $setup.streamMode) {
                ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Transparent: nothing over the camera. Lower Third: each slide shows in the lower third chosen for its type in Screens by Type, or its presentation's or theme's own; anything without one leaves the camera clear. Full Screen: the room's slide, edge to edge.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LiveAssistSettingsForm: View {
    @Bindable private var assist = LiveAssist.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveAssistInputPicker()
            Toggle("Advance lyrics as they're sung", isOn: $assist.advancesAutomatically)
            Slider(value: $assist.autoAdvanceConfidence, in: 0.5...0.95) {
                Text("Advance when \(Int(assist.autoAdvanceConfidence * 100))% sure")
            }
            .disabled(!assist.advancesAutomatically)
            Text("Turn on Follow in a song's slide grid header. Off: Follow only outlines the next slide.")
                .font(.caption).foregroundStyle(.secondary)
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
