import Foundation
import Observation
import PresenterCore
import Security
import SwiftUI

/// Keeps the next few weeks of Planning Center plans as Screens services and
/// refreshes them every few minutes, so a change in PCO (a swapped song, a new
/// key, a reordered set) shows up here without anyone re-importing.
@MainActor
@Observable
final class PlanningCenterSync {
    static let shared = PlanningCenterSync()

    private static let typesKey = "pco.serviceTypeIDs"
    private static let weeksKey = "pco.weeksAhead"
    private static let autoKey = "pco.autoSync"
    private static let importedSongsKey = "pco.importedSongs"
    static let refreshInterval: TimeInterval = 10 * 60

    var appID: String { didSet { Keychain.save(appID, account: "app-id") } }
    var secret: String { didSet { Keychain.save(secret, account: "secret") } }
    var serviceTypeIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(serviceTypeIDs), forKey: Self.typesKey) }
    }
    var weeksAhead: Int { didSet { UserDefaults.standard.set(weeksAhead, forKey: Self.weeksKey) } }
    var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Self.autoKey)
            scheduleTimer()
        }
    }

    private(set) var serviceTypes: [PCOClient.ServiceType] = []
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?

    private weak var model: AppModel?
    private var timer: Timer?

    var client: PCOClient { PCOClient(appID: appID, secret: secret) }

    private init() {
        let defaults = UserDefaults.standard
        appID = Keychain.load(account: "app-id") ?? ""
        secret = Keychain.load(account: "secret") ?? ""
        serviceTypeIDs = Set(defaults.stringArray(forKey: Self.typesKey) ?? [])
        weeksAhead = defaults.object(forKey: Self.weeksKey) as? Int ?? 5
        autoSync = defaults.object(forKey: Self.autoKey) as? Bool ?? true
    }

    func attach(_ model: AppModel) {
        self.model = model
        scheduleTimer()
        if autoSync, client.isConfigured, !serviceTypeIDs.isEmpty {
            Task { await sync() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoSync else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                let sync = PlanningCenterSync.shared
                if sync.client.isConfigured, !sync.serviceTypeIDs.isEmpty { await sync.sync() }
            }
        }
    }

    func loadServiceTypes() async {
        do {
            serviceTypes = try await client.serviceTypes()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Sync

    func sync() async {
        guard let model, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if serviceTypes.isEmpty { serviceTypes = try await client.serviceTypes() }
            await model.resident.ready([.service])
            let candidates = ((try? await model.client.presentationMatchKeys()) ?? []).map {
                ServiceLinkLogic.Candidate(id: $0.id, name: $0.name, ccliNumber: $0.ccliNumber, ccliSongTitle: $0.ccliTitle)
            }
            var created = 0, updated = 0, songsImported = 0
            for typeID in serviceTypeIDs.sorted() {
                let typeName = serviceTypes.first { $0.id == typeID }?.name
                let plans = try await client.futurePlans(serviceTypeID: typeID, limit: max(1, weeksAhead))
                for (index, plan) in plans.enumerated() {
                    let existing = model.resident.services.values.first { $0.mxuPlanHexId == plan.id }
                    if let existing, existing.mxuPlanVersion == plan.updatedAt, existing.mxuSyncPaused != true {
                        continue
                    }
                    if existing?.mxuSyncPaused == true { continue }
                    let planItems = try await client.items(serviceTypeID: typeID, planID: plan.id)
                    var imported = 0
                    let items = PCOPlanSync.items(
                        for: planItems, serviceTypeName: typeName, rules: model.serviceLinkRules,
                        existing: existing?.items ?? []
                    ) { planItem in
                        self.songReference(for: planItem, candidates: candidates, model: model, imported: &imported)
                    }
                    songsImported += imported
                    let name = PCOPlanSync.serviceName(for: plan)
                    let date = PCOPlanSync.serviceDate(for: plan)
                    if let existing {
                        model.updateService(existing.id) { service in
                            service.items = items
                            service.name = name
                            service.serviceDate = date
                            service.mxuPlanVersion = plan.updatedAt
                            service.mxuServiceTypeName = typeName
                        }
                        updated += 1
                    } else {
                        var service = Service(
                            id: UUID().uuidString, name: name, serviceDate: date, items: items,
                            origin: PCOPlanSync.origin, mxuPlanHexId: plan.id,
                            mxuServiceTypeName: typeName, mxuPlanVersion: plan.updatedAt)
                        service.mxuDerivedName = name
                        model.createInDrive(service)
                        created += 1
                    }
                    if index == 0 { await applyKeys(items, model: model) }
                }
            }
            lastSync = .now
            lastError = nil
            var parts: [String] = []
            if created > 0 { parts.append("\(created) new") }
            if updated > 0 { parts.append("\(updated) updated") }
            if songsImported > 0 { parts.append("\(songsImported) songs imported") }
            lastSummary = parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Library song for a plan song: the one imported for this PCO song
    /// before, else a CCLI/title match, else a new song from the
    /// arrangement's chord chart (or lyrics).
    private func songReference(
        for planItem: PCOClient.Item, candidates: [ServiceLinkLogic.Candidate],
        model: AppModel, imported: inout Int
    ) -> (refId: String, arrangementId: String?)? {
        var known = UserDefaults.standard.dictionary(forKey: Self.importedSongsKey) as? [String: String] ?? [:]
        let songKey = [planItem.song?.id, planItem.arrangement?.id].compactMap { $0 }.joined(separator: "/")
        if let id = known[songKey], model.libraryEntry(id) != nil {
            return (id, nil)
        }
        var probe = ServiceItem(id: "", itemKind: .info, name: planItem.title, refId: "")
        probe.mxuSongTitle = planItem.song?.title ?? planItem.title
        probe.mxuCcliNumber = planItem.song?.ccliNumber
        if case .link(_, let refId) = ServiceLinkLogic.resolve(
            item: probe, serviceTypeName: nil, rules: ServiceLinkRules(id: "", rules: []), candidates: candidates) {
            return (refId, nil)
        }
        guard let presentation = Self.importSong(planItem, themeId: model.slideBuilding.lyricsImportThemeId ?? "") else {
            return nil
        }
        model.createInDrive(presentation)
        known[songKey] = presentation.id
        UserDefaults.standard.set(known, forKey: Self.importedSongsKey)
        imported += 1
        return (presentation.id, presentation.defaultArrangementId)
    }

    static func importSong(_ planItem: PCOClient.Item, themeId: String) -> Presentation? {
        let arrangement = planItem.arrangement
        let source: String
        if let chart = arrangement?.chordChart, !chart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = ChordChartImport.chordPro(fromChart: chart)
        } else if let lyrics = arrangement?.lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = lyrics
        } else {
            return nil
        }
        let title = planItem.song?.title ?? planItem.title
        var presentation = LyricTextImporter.makePresentation(source, fallbackTitle: title, themeId: themeId)
        presentation.name = title
        presentation.presentationKind = .song
        presentation.category = PresentationTypes.worship
        if presentation.musicKey == nil { presentation.musicKey = arrangement?.chordChartKey }
        var ccli = presentation.ccli ?? CCLIInfo()
        ccli.songNumber = ccli.songNumber ?? planItem.song?.ccliNumber
        ccli.songTitle = ccli.songTitle ?? planItem.song?.title
        ccli.author = ccli.author ?? planItem.song?.author
        ccli.copyright = ccli.copyright ?? planItem.song?.copyright
        presentation.ccli = ccli
        if let arrangement, let sections = presentation.sections,
           let order = PCOPlanSync.arrangement(
               named: arrangement.name, sequence: arrangement.sequence, sections: sections) {
            presentation.arrangements = (presentation.arrangements ?? []) + [order]
            presentation.defaultArrangementId = order.id
        }
        return presentation
    }

    /// The upcoming service's keys become each song's display key, so
    /// chords and Nashville numbers on stage match what the band plays.
    private func applyKeys(_ items: [ServiceItem], model: AppModel) async {
        for item in items {
            guard let key = ServiceLinkLogic.pendingSongKey(for: item),
                  let presentation = try? await model.client.loadValue(Presentation.self, id: item.refId),
                  let update = ServiceLinkLogic.songKeyUpdate(playing: key, presentation: presentation)
            else { continue }
            model.updatePresentation(item.refId) { $0.displayKey = update.displayKey }
        }
    }

    private enum Keychain {
        static let service = "org.hopejc.screens.pco"

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

struct PlanningCenterSettingsForm: View {
    @Bindable private var sync = PlanningCenterSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Application ID", text: $sync.appID)
                .textFieldStyle(.roundedBorder)
            SecureField("Secret", text: $sync.secret)
                .textFieldStyle(.roundedBorder)
            Text("Create a personal access token at api.planningcenteronline.com › Personal Access Tokens.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Load Service Types") { Task { await sync.loadServiceTypes() } }
                    .disabled(!sync.client.isConfigured)
                Spacer()
            }
            if !sync.serviceTypes.isEmpty {
                Text("Sync these service types:").font(.callout)
                ForEach(sync.serviceTypes) { type in
                    Toggle("\(type.name)  (\(type.id))", isOn: Binding(
                        get: { sync.serviceTypeIDs.contains(type.id) },
                        set: { on in
                            if on { sync.serviceTypeIDs.insert(type.id) } else { sync.serviceTypeIDs.remove(type.id) }
                        }))
                }
            }
            Stepper("Plans ahead: \(sync.weeksAhead)", value: $sync.weeksAhead, in: 1...12)
            Toggle("Keep services updated automatically (every 10 minutes)", isOn: $sync.autoSync)
            HStack {
                Button(sync.isSyncing ? "Syncing…" : "Sync Now") { Task { await sync.sync() } }
                    .disabled(sync.isSyncing || !sync.client.isConfigured || sync.serviceTypeIDs.isEmpty)
                if let summary = sync.lastSummary, let date = sync.lastSync {
                    Text("\(summary) · \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = sync.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Songs link to your library by CCLI number or title; new ones are built from the arrangement's chord chart. Other items (Countdown, Announcements…) link the way you link them once — each week fills in the same way.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if sync.client.isConfigured, sync.serviceTypes.isEmpty { await sync.loadServiceTypes() } }
    }
}
