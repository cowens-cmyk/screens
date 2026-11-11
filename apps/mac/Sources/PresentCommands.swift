import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct PresentCommands: Commands {
    @FocusedValue(\.serviceControls) private var focusedControls
    /// The app's one ServiceControls. Live Assist, Media Library and
    /// Settings don't publish the focused value, and a clear pressed while
    /// one of them is in front still has to take the slide down.
    let fallback: ServiceControls?

    @AppStorage(PresentLayoutController.lockedKey) private var runOnly = false

    private var controls: ServiceControls? { focusedControls ?? fallback }

    var body: some Commands {
        CommandMenu("Present") {
            Button("Clear Slides") { controls?.clear(function: .slides) }
                .keyboardShortcut(command: .clearSlides)
                .disabled(controls == nil)
            Button("Clear Media") { controls?.clear(function: .media) }
                .keyboardShortcut(command: .clearMedia)
                .disabled(controls == nil)
            Button("Clear Alerts") { controls?.clear(function: .alerts) }
                .keyboardShortcut(command: .clearAlerts)
                .disabled(controls == nil)
            Toggle("Black Screen", isOn: Binding(
                get: { controls?.isBlack ?? false },
                set: { controls?.setBlack($0) }))
                .keyboardShortcut(command: .toggleBlack)
                .disabled(controls == nil)
            Divider()
            Menu("Clear Layer") {

                ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                    Button("Clear \(layer.displayName)") { controls?.clear(layer: layer) }
                }
            }
            .disabled(controls == nil)
            Button("Clear All") { controls?.clearAll() }
                .keyboardShortcut(command: .clearAll)
                .disabled(controls == nil)
            Divider()
            // Back to the message's length, stopped, ready for the next
            // service.
            Button("Reset Sermon Timer") { controls?.resetSermonTimer() }
                .keyboardShortcut(command: .resetSermonTimer)
                .disabled(controls == nil)
            Toggle("Sermon Timer Resets at Service Start", isOn: Binding(
                get: { controls?.sermonTimerResetsAtServiceStart ?? false },
                set: { controls?.sermonTimerResetsAtServiceStart = $0 }))
                // A per-Mac setting, so Simple Mode locks it like Settings.
                .disabled(controls == nil || runOnly)
        }
    }
}
