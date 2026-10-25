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
    var esvKey: String {
        didSet {
            Keychain.save(esvKey, account: "esv")
            if translation == nil, !esvKey.isEmpty { translation = .esv }
        }
    }

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
        let esv = Keychain.load(account: "esv") ?? ""
        esvKey = esv
        // ESV is Hope's translation: it's the default whenever an ESV key is
        // in place and nobody has picked another.
        translation = defaults.data(forKey: Self.translationKey)
            .flatMap { try? JSONDecoder().decode(BibleTranslation.self, from: $0) }
            ?? (esv.isEmpty ? nil : .esv)
        keepsLineBreaks = defaults.bool(forKey: Self.keepLineBreaksKey)
        showsVerseNumbers = defaults.object(forKey: Self.verseNumbersKey) as? Bool ?? true
        // Once, on the update that made ESV the default, a Mac that had
        // picked another translation moves to ESV; after that its choice holds.
        if !defaults.bool(forKey: "bible.esvDefaultApplied"), !esv.isEmpty {
            translation = .esv
            // didSet doesn't run in init, so store it here.
            defaults.set(try? JSONEncoder().encode(BibleTranslation.esv), forKey: Self.translationKey)
            defaults.set(true, forKey: "bible.esvDefaultApplied")
        }
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

    /// Through SecretStore, so the keys follow the church's iCloud Keychain
    /// once the app is signed for it; until then they stay on this Mac.
    private enum Keychain {
        static let service = "org.hopejc.screens.bible"

        static func load(account: String) -> String? {
            SecretStore.load(service: service, account: account)
        }

        static func save(_ secret: String, account: String) {
            SecretStore.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), service: service, account: account)
        }
    }
}

/// Settings › Bible: the translation services and the default scripture and
/// points themes. BibleSettings reads its keys from the Keychain when it is
/// first used; building this pane only when Bible is chosen keeps that read
/// off Settings' first appearance.
struct BibleSettingsPane: View {
    let model: AppModel?

    var body: some View {
        Form {
            BibleSettingsForm()
            if let model {
                Section {
                    ScriptureThemeSetting(model: model)
                } header: {
                    SettingsHeader(id: "bible.themes")
                } footer: {
                    Text(SettingsIndex.entry("bible.themes")?.caption ?? "")
                }
            }
        }
        .settingsForm()
    }
}

/// The translation keys, the default translation and the passage's text
/// options, as form sections.
struct BibleSettingsForm: View {
    @Bindable private var settings = BibleSettings.shared

    var body: some View {
        Section {
            SecureField("API.Bible key", text: $settings.apiBibleKey)
            SecureField("ESV API key", text: $settings.esvKey)
        } header: {
            SettingsHeader(id: "bible.sources")
        } footer: {
            Text("API.Bible is free at api.bible, with many translations; licensed ones like NIV need the publisher's approval in your API.Bible account. ESV is free for churches at api.esv.org.")
        }
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.translation) {
                        Text("None").tag(BibleTranslation?.none)
                        ForEach(settings.translations) { translation in
                            Text("\(translation.abbreviation) — \(translation.name)").tag(Optional(translation))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Button(settings.isLoading ? "Loading…" : "Refresh") {
                        Task { await settings.refreshTranslations() }
                    }
                    .disabled(!settings.hasAnyKey || settings.isLoading)
                }
            } label: {
                Text("Default translation")
            }
            .settingsAnchor("bible.translation")
            if let error = settings.loadError {
                Text(error).font(.subheadline).foregroundStyle(.red)
            }
        } footer: {
            Text(SettingsIndex.entry("bible.sources")?.caption ?? "")
        }
        Section {
            Toggle("Keep the passage's line breaks", isOn: $settings.keepsLineBreaks)
                .settingsAnchor("bible.text")
            Toggle("Show verse numbers", isOn: $settings.showsVerseNumbers)
        } header: {
            Text("Passage Text")
        }
        .task { await settings.refreshTranslations() }
    }
}
