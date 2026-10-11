import Foundation
import Observation
import PresenterCore
import Security
import SwiftUI

/// Bible service keys live in the Keychain; the chosen translation and text
/// options live in this Mac's defaults. The Bible slide template (a theme
/// with a "Bible" slide) is a library setting, shared with the team.
@MainActor
@Observable
final class BibleSettings {
    static let shared = BibleSettings()

    private static let translationKey = "bible.translation"
    private static let keepLineBreaksKey = "bible.keepLineBreaks"
    private static let verseNumbersKey = "bible.verseNumbers"

    var apiBibleKey: String { didSet { Keychain.save(apiBibleKey, account: "api-bible") } }
    var esvKey: String { didSet { Keychain.save(esvKey, account: "esv") } }

    var translation: BibleTranslation? {
        didSet {
            let data = translation.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: Self.translationKey)
        }
    }

    var keepsLineBreaks: Bool {
        didSet { UserDefaults.standard.set(keepsLineBreaks, forKey: Self.keepLineBreaksKey) }
    }

    var showsVerseNumbers: Bool {
        didSet { UserDefaults.standard.set(showsVerseNumbers, forKey: Self.verseNumbersKey) }
    }

    private(set) var translations: [BibleTranslation] = []
    private(set) var loadError: String?
    private(set) var isLoading = false

    var service: BibleService { BibleService(keys: BibleKeys(apiBible: apiBibleKey, esv: esvKey)) }
    var hasAnyKey: Bool { !apiBibleKey.isEmpty || !esvKey.isEmpty }

    var format: ScriptureFormat {
        ScriptureFormat(keepsLineBreaks: keepsLineBreaks, showsVerseNumbers: showsVerseNumbers)
    }

    private init() {
        let defaults = UserDefaults.standard
        apiBibleKey = Keychain.load(account: "api-bible") ?? ""
        esvKey = Keychain.load(account: "esv") ?? ""
        translation = defaults.data(forKey: Self.translationKey)
            .flatMap { try? JSONDecoder().decode(BibleTranslation.self, from: $0) }
        keepsLineBreaks = defaults.bool(forKey: Self.keepLineBreaksKey)
        showsVerseNumbers = defaults.object(forKey: Self.verseNumbersKey) as? Bool ?? true
    }

    func refreshTranslations() async {
        guard hasAnyKey else {
            translations = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            translations = try await service.translations()
            loadError = nil
            if translation == nil || !translations.contains(where: { $0.id == translation?.id }) {
                translation = translations.first { $0.abbreviation == "ESV" } ?? translations.first
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private enum Keychain {
        static let service = "org.hopejc.screens.bible"

        static func load(account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func save(_ secret: String, account: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var attributes = query
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

struct BibleSettingsForm: View {
    @Bindable private var settings = BibleSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("API.Bible key", text: $settings.apiBibleKey)
                .textFieldStyle(.roundedBorder)
            Text("Free at api.bible — many translations. Licensed ones (like NIV) need the publisher's approval in your API.Bible account.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("ESV API key", text: $settings.esvKey)
                .textFieldStyle(.roundedBorder)
            Text("Free for churches at api.esv.org.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Default translation", selection: $settings.translation) {
                    Text("None").tag(BibleTranslation?.none)
                    ForEach(settings.translations) { translation in
                        Text("\(translation.abbreviation) — \(translation.name)").tag(Optional(translation))
                    }
                }
                Button(settings.isLoading ? "Loading…" : "Refresh") {
                    Task { await settings.refreshTranslations() }
                }
                .disabled(!settings.hasAnyKey || settings.isLoading)
            }
            if let error = settings.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Keep the passage's line breaks", isOn: $settings.keepsLineBreaks)
            Toggle("Show verse numbers", isOn: $settings.showsVerseNumbers)
        }
        .task { await settings.refreshTranslations() }
    }
}
