import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct PresentCommands: Commands {
    @FocusedValue(\.serviceControls) private var controls

    var body: some Commands {
        CommandMenu("Present") {
            Button("Clear Slides") { controls?.clear(function: .slides) }
                .keyboardShortcut(command: .clearSlides)
            Button("Clear Media") { controls?.clear(function: .media) }
                .keyboardShortcut(command: .clearMedia)
            Button("Clear Alerts") { controls?.clear(function: .alerts) }
                .keyboardShortcut(command: .clearAlerts)
            Divider()
            Menu("Clear Layer") {

                ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                    Button("Clear \(layer.displayName)") { controls?.clear(layer: layer) }
                }
            }
            Button("Clear All") { controls?.clearAll() }
                .keyboardShortcut(command: .clearAll)
            Divider()
            // Back to the message's length, stopped, ready for the next
            // service.
            Button("Reset Sermon Timer") { controls?.resetSermonTimer() }
                .keyboardShortcut(command: .resetSermonTimer)
                .disabled(controls == nil)
            Toggle("Sermon Timer Resets at Service Start", isOn: Binding(
                get: { controls?.sermonTimerResetsAtServiceStart ?? false },
                set: { controls?.sermonTimerResetsAtServiceStart = $0 }))
                .disabled(controls == nil)
        }
    }
}
