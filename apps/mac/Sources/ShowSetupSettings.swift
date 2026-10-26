import PresenterCore
import SwiftUI

/// Settings › Livestream: the Livestream switch and each part of the
/// service's lower third. The output and alpha key are with the other
/// screens in Settings › Screens.
struct LivestreamSettingsPane: View {
    let model: AppModel?
    let controls: ServiceControls?
    @Bindable private var setup = ShowSetup.shared

    var body: some View {
        Form {
            Section {
                SettingsRow("show.streamMode") {
                    Picker("", selection: $setup.streamMode) {
                        ForEach(ShowSetup.StreamMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Output and alpha key") {
                    Button("Show in Screens") {
                        SettingsRouter.shared.open(.screens, entry: "screens.livestream")
                    }
                }
            } header: {
                Text("Livestream Switch")
            } footer: {
                Text("The switch is also in the Livestream card of the screens panel.")
            }
            if let model {
                Section {
                    ScreensByTypeForm(model: model, render: controls?.render)
                        .padding(.vertical, 4)
                } header: {
                    SettingsHeader(id: "show.typeScreens")
                }
            }
        }
        .settingsForm()
    }
}

/// Settings › Stage: what the stage display shows, how messages to it
/// behave, and what each type of presentation does when it goes live.
struct StageSettingsPane: View {
    let model: AppModel?
    let controls: ServiceControls?
    @Bindable private var setup = ShowSetup.shared
    @AppStorage(ServiceControls.nextSkipsBlanksKey) private var nextSkipsBlanks = true

    var body: some View {
        Form {
            Section {
                SettingsRow("stage.mode") {
                    Picker("", selection: $setup.stageMode) {
                        ForEach(ShowSetup.StageMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggle("stage.follows", isOn: $setup.stageFollowsItems)
                SettingsToggle("stage.videos", isOn: $setup.stageShowsVideos)
                SettingsToggle("present.nextSkipsBlanks", isOn: Binding(
                    get: { nextSkipsBlanks },
                    set: {
                        nextSkipsBlanks = $0
                        controls?.refreshNextSlide()
                    }
                ))
            } header: {
                Text("Stage Display")
            } footer: {
                Text("Which display shows the stage is in Settings › Screens.")
            }
            Section {
                SettingsRow("show.stageMessages") {
                    Picker("", selection: $setup.stageMessageDuration) {
                        ForEach(StageMessageDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            } header: {
                Text("Messages")
            }
            if let controls {
                SermonTimerResetSection(controls: controls)
            }
            if let model {
                Section {
                    PresentationTypeRulesForm(model: model)
                } header: {
                    SettingsHeader(id: "present.types")
                } footer: {
                    Text("Example: Sermon sets the stage layout and starts the sermon timer. Songs count as Worship.")
                }
            }
        }
        .settingsForm()
    }
}

/// Settings › Stage › Sermon Timer: whether each service's start sets the
/// timer back on this Mac, and when that happens next.
private struct SermonTimerResetSection: View {
    @Bindable var controls: ServiceControls
    @AppStorage(ServiceStation.runsServiceKey) private var runsService = false

    var body: some View {
        Section {
            SettingsToggle("stage.sermonTimerReset", isOn: $controls.sermonTimerResetsAtServiceStart)
            LabeledContent("Reset now") {
                Button("Reset Sermon Timer") { controls.resetSermonTimer() }
            }
        } header: {
            Text("Sermon Timer")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        guard controls.sermonTimerResetsAtServiceStart else {
            return "Off on this Mac. Present › Reset Sermon Timer (⌃⌘0) still sets it back by hand."
        }
        guard runsService else {
            return "This Mac doesn't run the service (Settings › General › Run on this Mac), so another Mac resets it."
        }
        guard let next = controls.nextSermonTimerReset else { return "No service start left today." }
        return "Next reset \(next.formatted(date: .omitted, time: .shortened))."
    }
}

/// Settings › Live Listening: what Live Assist hears and what it does with
/// it.
struct LiveListeningSettingsPane: View {
    @Bindable private var assist = LiveAssist.shared

    var body: some View {
        Form {
            Section {
                LiveAssistInputPicker()
            } header: {
                SettingsHeader(id: "show.liveAssist")
            } footer: {
                Text(SettingsIndex.entry("show.liveAssist")?.caption ?? "")
            }
            Section {
                SettingsToggle("liveAssist.lyrics", isOn: $assist.advancesAutomatically)
                LabeledContent {
                    Slider(value: $assist.autoAdvanceConfidence, in: 0.5...0.95)
                        .frame(width: 200)
                } label: {
                    Text("Advance when \(Int(assist.autoAdvanceConfidence * 100))% sure")
                }
                .disabled(!assist.advancesAutomatically)
            } header: {
                Text("Songs")
            }
            Section {
                SettingsToggle("liveAssist.scripture", isOn: $assist.detectsScripture)
            } header: {
                Text("Sermon")
            } footer: {
                Text("Detected passages show in Window › Live Assist, ready to put on screen.")
            }
        }
        .settingsForm()
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
