import AppKit
import PresenterCore
import SwiftUI

/// Where the Assistant's choices live. The API key is the one Sermon import
/// already keeps in the Keychain (ClaudeClient); only the model is new.
enum AssistantPreferences {
    static var model: AssistantModel {
        AssistantModel.stored(UserDefaults.standard.string(forKey: AssistantModel.defaultsKey))
    }

    static var hasKey: Bool {
        !ClaudeClient.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where to send someone who has no key yet.
    static let keyLocation = "Settings › Assistant"

    @MainActor
    static func openSettings() {
        SettingsRouter.shared.open(.assistant, entry: "api.assistant")
    }
}

/// Settings › Assistant: the Anthropic key everything Claude does here
/// shares, the Assistant's model, and sermon import.
struct AssistantSettingsPane: View {
    let model: AppModel?
    @AppStorage(AssistantModel.defaultsKey) private var modelRaw = AssistantModel.opus.rawValue

    var body: some View {
        Form {
            Section {
                SettingsRow("api.assistant") {
                    // Reads the Keychain on appear, never in a view body.
                    ClaudeKeyField()
                        .labelsHidden()
                        .frame(width: 260)
                }
                SettingsRow("assistant.model") {
                    Picker("", selection: $modelRaw) {
                        ForEach(AssistantModel.allCases) { model in
                            Text(model.title).tag(model.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text(AssistantModel.stored(modelRaw).detail
                    + " Open the Assistant from Window › Assistant (⇧⌘A).")
            }
            if let model {
                Section {
                    SermonImportSettingsForm(model: model)
                } header: {
                    SettingsHeader(id: "bible.sermon")
                } footer: {
                    Text(SettingsIndex.entry("bible.sermon")?.caption ?? "")
                }
            }
        }
        .settingsForm()
    }
}
