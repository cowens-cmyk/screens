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
    static let keyLocation = "Settings › Network & API › Assistant"

    @MainActor
    static func openSettings() {
        SettingsRouter.shared.pending = .api
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// Settings › Network & API › Assistant.
struct AssistantSettingsForm: View {
    @AppStorage(AssistantModel.defaultsKey) private var modelRaw = AssistantModel.opus.rawValue
    @State private var key = ClaudeClient.apiKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Anthropic API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { _, value in ClaudeClient.apiKey = value }
            Text("From console.anthropic.com › API Keys. Sermon import uses the same key.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Model", selection: $modelRaw) {
                ForEach(AssistantModel.allCases) { model in
                    Text(model.title).tag(model.rawValue)
                }
            }
            Text(AssistantModel.stored(modelRaw).detail)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
