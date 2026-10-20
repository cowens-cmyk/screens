import Foundation
import Observation
import PresenterCore
import SwiftUI

/// Loads upcoming Sunday plans from Shepherd as Screens services and checks
/// again every few minutes. Songs link only
/// to presentations already in the library; a song with none stays in the
/// service flagged "No slides" until one is imported.
@MainActor
@Observable
final class ShepherdSync {
    static let shared = ShepherdSync()

    private static let keyService = "org.hopejc.screens.shepherd"
    private static let serviceTypeKey = "shepherd.serviceType"
    private static let weeksKey = "shepherd.weeksAhead"
    private static let sundaysKey = "shepherd.sundaysOnly"
    private static let autoKey = "shepherd.autoSync"
    static let refreshInterval: TimeInterval = 10 * 60

    var apiKey: String {
        didSet { SecretStore.save(apiKey, service: Self.keyService, account: "api-key") }
    }
    /// A Shepherd service type name or id ("Sunday Worship"); empty takes every type.
    var serviceType: String { didSet { UserDefaults.standard.set(serviceType, forKey: Self.serviceTypeKey) } }
    var weeksAhead: Int { didSet { UserDefaults.standard.set(weeksAhead, forKey: Self.weeksKey) } }
    var sundaysOnly: Bool { didSet { UserDefaults.standard.set(sundaysOnly, forKey: Self.sundaysKey) } }
    var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Self.autoKey)
            scheduleTimer()
        }
    }

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    private(set) var connectedApp: String?

    private weak var model: AppModel?
    private var timer: Timer?

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var client: ShepherdClient { ShepherdClient(apiKey: apiKey) }

    private init() {
        let defaults = UserDefaults.standard
        apiKey = SecretStore.load(service: Self.keyService, account: "api-key") ?? ""
        serviceType = defaults.string(forKey: Self.serviceTypeKey) ?? ""
        weeksAhead = defaults.object(forKey: Self.weeksKey) as? Int ?? 3
        sundaysOnly = defaults.object(forKey: Self.sundaysKey) as? Bool ?? true
        autoSync = defaults.object(forKey: Self.autoKey) as? Bool ?? true
    }

    func attach(_ model: AppModel) {
        self.model = model
        scheduleTimer()
        if autoSync, isConfigured {
            model.whenLibraryReady { Task { await self.sync() } }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoSync else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                let sync = ShepherdSync.shared
                if sync.isConfigured { await sync.sync() }
            }
        }
    }

    /// Checks the key and shows which Shepherd connection it belongs to.
    func testConnection() async {
        do {
            let ping = try await client.ping()
            connectedApp = ping.app
            lastError = ping.scopes.contains("services:read")
                ? nil : "This key can't read services. Ask a Shepherd admin to add the services:read scope."
        } catch {
            connectedApp = nil
            lastError = error.localizedDescription
        }
    }

    func sync() async {
        guard let model, isConfigured, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            await model.resident.ready([.service])
            let candidates = ((try? await model.client.presentationMatchKeys()) ?? []).map {
                ServiceLinkLogic.Candidate(id: $0.id, name: $0.name, ccliNumber: $0.ccliNumber, ccliSongTitle: $0.ccliTitle)
            }
            let (from, to) = Self.window(weeks: weeksAhead)
            var plans = try await client.plans(from: from, to: to, serviceType: serviceType.isEmpty ? nil : serviceType)
            if sundaysOnly { plans = plans.filter(Self.isSunday) }

            var created = 0, updated = 0
            for (index, plan) in plans.enumerated() {
                let existing = model.resident.services.values.first {
                    $0.origin == ShepherdPlanSync.origin && $0.mxuPlanHexId == plan.id
                }
                if existing?.mxuSyncPaused == true { continue }
                let version = ISO8601DateFormatter().string(from: plan.updatedAt)
                // An unchanged plan is still re-read while it has flagged
                // songs, so importing the song links it on the next pass.
                if let existing, existing.mxuPlanVersion == version, !Self.hasFlaggedSongs(existing) { continue }

                let detail = try await client.plan(id: plan.id)
                let items = ShepherdPlanSync.items(
                    for: detail, rules: model.serviceLinkRules, existing: existing?.items ?? []
                ) { song in Self.librarySong(for: song, candidates: candidates) }
                let name = ShepherdPlanSync.serviceName(for: detail)
                let date = ShepherdPlanSync.serviceDate(for: detail)
                if let existing {
                    if existing.items != items || existing.name != name || existing.mxuPlanVersion != version {
                        let times = Self.planTimes(detail)
                        model.updateService(existing.id) { service in
                            service.items = items
                            service.name = name
                            service.serviceDate = date
                            service.mxuPlanVersion = version
                            service.mxuServiceTypeName = detail.serviceType.name
                            service.mxuPlanTimes = times
                        }
                        updated += 1
                    }
                } else {
                    var service = Service(
                        id: UUID().uuidString, name: name, serviceDate: date, items: items,
                        origin: ShepherdPlanSync.origin, mxuPlanHexId: plan.id,
                        mxuServiceTypeName: detail.serviceType.name, mxuPlanVersion: version)
                    service.mxuDerivedName = name
                    service.mxuPlanTimes = Self.planTimes(detail)
                    model.createInDrive(service)
                    created += 1
                }
                if index == 0 { await applyKeys(items, model: model) }
            }

            let flagged = model.resident.services.values
                .filter { $0.origin == ShepherdPlanSync.origin }
                .reduce(0) { $0 + Self.flaggedSongs(in: $1.items) }
            lastSync = .now
            lastError = nil
            var parts: [String] = []
            if created > 0 { parts.append("\(created) new") }
            if updated > 0 { parts.append("\(updated) updated") }
            if parts.isEmpty { parts.append(plans.isEmpty ? "No upcoming plans" : "Up to date") }
            if flagged > 0 { parts.append("\(flagged) song\(flagged == 1 ? "" : "s") need slides") }
            lastSummary = parts.joined(separator: ", ")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// After a song is imported: re-read plans that flagged songs, once the
    /// new presentation is in the library index.
    func relinkFlaggedSongs() async {
        try? await Task.sleep(for: .seconds(1))
        await sync()
    }

    // MARK: Helpers

    /// Service and rehearsal times, for "5 minutes before each service" rules.
    static func planTimes(_ plan: ShepherdClient.PlanDetail) -> [MxUPlanTime] {
        let formatter = ISO8601DateFormatter()
        return plan.times.enumerated().map { index, time in
            MxUPlanTime(
                hexId: "\(plan.id)-\(index)", name: time.label ?? time.kind,
                startsAt: time.startsAt.map(formatter.string(from:)),
                isRehearsal: time.kind != "service")
        }
    }

    /// Today through `weeks` weeks ahead, in the church's calendar.
    static func window(weeks: Int, now: Date = .now) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let end = calendar.date(byAdding: .day, value: max(1, weeks) * 7, to: now) ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: now), formatter.string(from: end))
    }

    static func isSunday(_ plan: ShepherdClient.PlanSummary) -> Bool {
        guard let start = plan.startsAt else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.component(.weekday, from: start) == 1
    }

    static func flaggedSongs(in items: [ServiceItem]) -> Int {
        items.filter { $0.itemKind == .info && $0.refId.isEmpty && $0.mxuSongTitle != nil }.count
    }

    private static func hasFlaggedSongs(_ service: Service) -> Bool { flaggedSongs(in: service.items) > 0 }

    /// A library presentation for a plan song, by CCLI number or title.
    private static func librarySong(
        for song: PCOClient.Item, candidates: [ServiceLinkLogic.Candidate]
    ) -> (refId: String, arrangementId: String?)? {
        var probe = ServiceItem(id: "", itemKind: .info, name: song.title, refId: "")
        probe.mxuSongTitle = song.song?.title ?? song.title
        probe.mxuCcliNumber = song.song?.ccliNumber
        guard case .link(_, let refId) = ServiceLinkLogic.resolve(
            item: probe, serviceTypeName: nil, rules: ServiceLinkRules(id: "", rules: []), candidates: candidates)
        else { return nil }
        return (refId, nil)
    }

    /// The next service's keys become each song's display key, so chords and
    /// Nashville numbers on stage match what the band plays.
    private func applyKeys(_ items: [ServiceItem], model: AppModel) async {
        for item in items {
            guard let key = ServiceLinkLogic.pendingSongKey(for: item),
                  let presentation = try? await model.client.loadValue(Presentation.self, id: item.refId),
                  let update = ServiceLinkLogic.songKeyUpdate(playing: key, presentation: presentation)
            else { continue }
            model.updatePresentation(item.refId) { $0.displayKey = update.displayKey }
        }
    }
}

/// Settings › Services › Shepherd.
struct ShepherdSettingsForm: View {
    @Bindable private var sync = ShepherdSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Shepherd API key (shp_…)", text: $sync.apiKey)
                .textFieldStyle(.roundedBorder)
            Text("A Shepherd admin makes this under Connected apps, with the services:read scope.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Service type (blank for all)", text: $sync.serviceType)
                .textFieldStyle(.roundedBorder)
            Toggle("Sundays only", isOn: $sync.sundaysOnly)
            Stepper("Load \(sync.weeksAhead) week\(sync.weeksAhead == 1 ? "" : "s") ahead", value: $sync.weeksAhead, in: 1...12)
            Toggle("Check for changes every 10 minutes", isOn: $sync.autoSync)
            HStack {
                Button(sync.isSyncing ? "Loading…" : "Load Plans Now") { Task { await sync.sync() } }
                    .disabled(!sync.isConfigured || sync.isSyncing)
                Button("Test Key") { Task { await sync.testConnection() } }
                    .disabled(!sync.isConfigured)
                Spacer()
            }
            if let app = sync.connectedApp {
                Text("Connected as “\(app)”.").font(.caption).foregroundStyle(.secondary)
            }
            if let summary = sync.lastSummary, let when = sync.lastSync {
                Text("\(summary) · \(when.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = sync.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
