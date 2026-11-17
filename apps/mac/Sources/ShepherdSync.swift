import Foundation
import Observation
import PresenterCore
import SwiftUI

/// Loads upcoming Sunday plans from Shepherd as Screens services and checks
/// again every few minutes. Songs link to presentations already in the
/// library; a song with none gets one built from its Shepherd chord chart
/// (see ShepherdSongSync), or stays flagged "No slides" when Shepherd has
/// no words for it or song import is off.
@MainActor
@Observable
final class ShepherdSync {
    static let shared = ShepherdSync()

    private static let keyService = "org.hopejc.screens.shepherd"
    private static let serviceTypeKey = "shepherd.serviceType"
    private static let weeksKey = "shepherd.weeksAhead"
    private static let sundaysKey = "shepherd.sundaysOnly"
    private static let autoKey = "shepherd.autoSync"
    private static let midweekTypeKey = "shepherd.midweekServiceType"
    private static let midweekTemplateKey = "shepherd.midweekTemplate"
    static let refreshInterval: TimeInterval = 10 * 60

    var apiKey: String {
        didSet { SecretStore.save(apiKey, service: Self.keyService, account: "api-key") }
    }
    /// A Shepherd service type name or id ("Sunday Worship"); empty takes every type.
    var serviceType: String { didSet { UserDefaults.standard.set(serviceType, forKey: Self.serviceTypeKey) } }
    var weeksAhead: Int { didSet { UserDefaults.standard.set(weeksAhead, forKey: Self.weeksKey) } }
    var sundaysOnly: Bool { didSet { UserDefaults.standard.set(sundaysOnly, forKey: Self.sundaysKey) } }
    /// The Shepherd service type whose plans are built on a Screens template
    /// (ShepherdTemplatePlan): Wednesday Night, for Hope Students. Loaded on
    /// its own day whatever "Sundays only" says; empty loads none.
    var midweekServiceType: String {
        didSet { UserDefaults.standard.set(midweekServiceType, forKey: Self.midweekTypeKey) }
    }
    /// The template those plans are built on; empty picks one by name.
    var midweekTemplateID: String {
        didSet { UserDefaults.standard.set(midweekTemplateID, forKey: Self.midweekTemplateKey) }
    }
    var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Self.autoKey)
            scheduleTimer()
        }
    }

    /// Build and refresh planned songs from Shepherd's chord charts.
    var importSongs: Bool {
        didSet { UserDefaults.standard.set(importSongs, forKey: Self.importSongsKey) }
    }
    /// Songs edited here whose Shepherd chart has changed since, by
    /// presentation id. Each sync works it out again.
    var newerCharts: [String: ShepherdNewerChart] = [:]

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    private(set) var connectedApp: String?

    private weak var model: AppModel?
    /// What is on screen, so a song that is live isn't rebuilt under it.
    weak var controls: ServiceControls?
    private var timer: Timer?

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var client: ShepherdClient { ShepherdClient(apiKey: apiKey) }

    private init() {
        let defaults = UserDefaults.standard
        apiKey = SecretStore.load(service: Self.keyService, account: "api-key") ?? ""
        serviceType = defaults.string(forKey: Self.serviceTypeKey) ?? ""
        weeksAhead = defaults.object(forKey: Self.weeksKey) as? Int ?? 3
        sundaysOnly = defaults.object(forKey: Self.sundaysKey) as? Bool ?? true
        midweekServiceType = defaults.string(forKey: Self.midweekTypeKey) ?? ShepherdTemplatePlan.defaultServiceType
        midweekTemplateID = defaults.string(forKey: Self.midweekTemplateKey) ?? ""
        autoSync = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        importSongs = defaults.object(forKey: Self.importSongsKey) as? Bool ?? true
    }

    func attach(_ model: AppModel, controls: ServiceControls? = nil) {
        self.model = model
        self.controls = controls
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
            let candidates = await Self.linkCandidates(model)
            let (from, to) = Self.window(weeks: weeksAhead)
            var plans = try await client.plans(from: from, to: to, serviceType: serviceType.isEmpty ? nil : serviceType)
            if sundaysOnly { plans = plans.filter(Self.isSunday) }
            // Wednesday Night plans come on their own, whatever day filter
            // the Sunday plans have. When they can't be read, the ones
            // already here are left alone rather than taken for gone.
            let midweek = midweekServiceType.trimmingCharacters(in: .whitespaces)
            var midweekRead = true
            if !midweek.isEmpty {
                plans.removeAll { Self.isMidweek($0.serviceType, midweek) }
                do {
                    plans += try await client.plans(from: from, to: to, serviceType: midweek)
                        .filter { Self.isMidweek($0.serviceType, midweek) }
                } catch {
                    midweekRead = false
                }
                plans.sort { ($0.startsAt ?? .distantFuture, $0.id) < ($1.startsAt ?? .distantFuture, $1.id) }
            }
            // One plan per day (ShepherdDayPick): a day with more than one is
            // read in full to see which is the church's service.
            var details: [String: ShepherdClient.PlanDetail] = [:]
            let crowded = Dictionary(grouping: plans, by: ShepherdPlanSync.serviceDate(for:)).values.filter { $0.count > 1 }
            for plan in crowded.joined() { details[plan.id] = try await client.plan(id: plan.id) }
            let pick = ShepherdDayPick.pick(plans, songs: details.mapValues(ShepherdDayPick.songCount))
            plans = pick.kept

            var created = 0, updated = 0, waiting = 0
            let preService = model.preServiceSlideshowID()
            for (index, plan) in plans.enumerated() {
                let existing = model.resident.services.values.first {
                    $0.origin == ShepherdPlanSync.origin && $0.mxuPlanHexId == plan.id
                }
                if existing?.mxuSyncPaused == true { continue }
                let version = ISO8601DateFormatter().string(from: plan.updatedAt)
                // An unchanged plan is still re-read while it has flagged
                // songs, so importing the song links it on the next pass.
                // A plan still named the old way ("2026-11-22 — …") is read
                // once more to get its date written out.
                if let existing, existing.mxuPlanVersion == version, !Self.hasFlaggedSongs(existing),
                   !Self.hasNumericDateName(existing) { continue }

                let detail: ShepherdClient.PlanDetail
                if let read = details[plan.id] { detail = read } else { detail = try await client.plan(id: plan.id) }
                let rules = model.serviceLinkRules
                // A Wednesday Night plan is made from its template. With no
                // template in the library yet it still comes in, in
                // Shepherd's order like a Sunday plan but without Sunday's
                // pre-service slideshow, Transition and Walkout; plans made
                // once there is a template use it.
                let isMidweekPlan = Self.isMidweek(plan.serviceType, midweek)
                let hasTemplate = isMidweekPlan && ShepherdTemplatePlan.template(
                    for: midweek, chosenID: midweekTemplateID, in: Array(model.resident.services.values)) != nil
                if isMidweekPlan, existing.map(Self.isTemplateBuilt) ?? hasTemplate {
                    switch await syncTemplatePlan(
                        detail, existing: existing, version: version, rules: rules, candidates: candidates, model: model) {
                    case .created: created += 1
                    case .updated: updated += 1
                    case .waiting: waiting += 1
                    case .unchanged: break
                    }
                    if index == 0, let id = existing?.id ?? model.resident.services.value(
                        ShepherdDayPick.serviceID(forPlan: plan.id))?.id,
                       let items = model.resident.services.value(id)?.items {
                        await applyKeys(items, model: model)
                    }
                    continue
                }
                let opener = isMidweekPlan ? nil : preService
                let items = Self.planItems(
                    detail, over: existing, rules: rules, candidates: candidates, preService: opener)
                let name = ShepherdPlanSync.serviceName(for: detail)
                let date = ShepherdPlanSync.serviceDate(for: detail)
                if let existing {
                    if existing.items != items || existing.name != name || existing.mxuPlanVersion != version {
                        let times = Self.planTimes(detail)
                        let readRefs = Set(existing.items.map(\.refId))
                        // Main, not this Mac's version: the items are worked
                        // out from main. They are worked out again from the
                        // service as the write finds it, so an edit made while
                        // the plan was loading isn't put back; a song linked
                        // meanwhile is newer than `candidates`, and stays.
                        model.updateMainService(existing.id) { service in
                            let linkedSince = Set(service.items.map(\.refId)).subtracting(readRefs)
                            service.items = Self.planItems(
                                detail, over: service, rules: rules, candidates: candidates,
                                preService: opener, linkedSince: linkedSince)
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
                        id: ShepherdDayPick.serviceID(forPlan: plan.id), name: name, serviceDate: date, items: items,
                        origin: ShepherdPlanSync.origin, mxuPlanHexId: plan.id,
                        mxuServiceTypeName: detail.serviceType.name, mxuPlanVersion: version)
                    service.mxuDerivedName = name
                    service.mxuPlanTimes = Self.planTimes(detail)
                    if isMidweekPlan {
                        service.preServiceRemoved = true
                        service.transitionRemoved = true
                        service.walkoutRemoved = true
                    }
                    model.createInDrive(service)
                    created += 1
                }
                if index == 0 { await applyKeys(items, model: model) }
            }

            // The second plans already imported, and copies of one plan, go.
            let open = Set([model.currentServiceID].compactMap { $0 })
            let services = model.resident.services.values.filter {
                midweekRead || !Self.isMidweek(name: $0.mxuServiceTypeName ?? "", midweek)
            }
            let extra = ShepherdDayPick.duplicates(in: services, pick: pick, keep: open, window: from...to)
            for id in extra { model.client.delete(kind: .service, id: id) }

            let ids = plans.compactMap { plan in
                model.resident.services.values.first {
                    $0.origin == ShepherdPlanSync.origin && $0.mxuPlanHexId == plan.id
                }?.id
            }
            let songs = await refreshSongs(inServices: ids, importing: importSongs, model: model)

            let flagged = model.resident.services.values
                .filter { $0.origin == ShepherdPlanSync.origin }
                .reduce(0) { $0 + Self.flaggedSongs(in: $1.items) }
            lastSync = .now
            lastError = nil
            var parts: [String] = []
            if created > 0 { parts.append("\(created) new") }
            if updated > 0 { parts.append("\(updated) updated") }
            if !extra.isEmpty { parts.append("\(extra.count) duplicate plan\(extra.count == 1 ? "" : "s") removed") }
            if songs.imported > 0 { parts.append("\(songs.imported) song\(songs.imported == 1 ? "" : "s") imported") }
            if songs.updated > 0 { parts.append("\(songs.updated) song\(songs.updated == 1 ? "" : "s") updated") }
            if songs.arranged > 0 {
                parts.append("\(songs.arranged) arrangement\(songs.arranged == 1 ? "" : "s") from Shepherd")
            }
            if waiting > 0 {
                parts.append("\(waiting) \(midweek) plan\(waiting == 1 ? " waits" : "s wait") for a template")
            }
            if !midweekRead { parts.append("\(midweek) plans couldn't be read") }
            if parts.isEmpty { parts.append(plans.isEmpty ? "No upcoming plans" : "Up to date") }
            if !newerCharts.isEmpty {
                parts.append("\(newerCharts.count) edited song\(newerCharts.count == 1 ? " has" : "s have") a newer chart")
            }
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

    // MARK: Plans built on a template (Wednesday Night)

    /// A plan of the Wednesday Night type, by name or id.
    static func isMidweek(_ type: ShepherdClient.ServiceType, _ midweek: String) -> Bool {
        !midweek.isEmpty && (isMidweek(name: type.name, midweek) || type.id == midweek)
    }

    static func isMidweek(name: String, _ midweek: String) -> Bool {
        !midweek.isEmpty && name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(midweek) == .orderedSame
    }

    /// Built on the template: Shepherd gave it songs and nothing else. A
    /// Wednesday plan loaded in Shepherd's order before (with "Sundays only"
    /// off) stays that way.
    static func isTemplateBuilt(_ service: Service) -> Bool {
        !service.items.contains { $0.mxuSourceItemId != nil && $0.mxuKind != "song" }
    }

    enum TemplatePlanResult { case created, updated, unchanged, waiting }

    /// A Wednesday Night plan made from its template, or its songs, name,
    /// date and times brought up to date. `.waiting` when there's no
    /// template to make it from.
    private func syncTemplatePlan(
        _ detail: ShepherdClient.PlanDetail, existing: Service?, version: String, rules: ServiceLinkRules,
        candidates: [ServiceLinkLogic.Candidate], model: AppModel
    ) async -> TemplatePlanResult {
        let midweek = midweekServiceType.trimmingCharacters(in: .whitespaces)
        let template = ShepherdTemplatePlan.template(
            for: midweek, chosenID: midweekTemplateID, in: Array(model.resident.services.values))
        let date = ShepherdPlanSync.serviceDate(for: detail)
        let title = detail.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = !title.isEmpty ? title
            : template.map { $0.name.replacingOccurrences(of: " Template", with: "") } ?? detail.serviceType.name
        let name = ShepherdPlanSync.planName(date: date, label: label)
        let times = Self.planTimes(detail)

        if let existing {
            let songs = Self.templateSongs(detail, over: existing.items, rules: rules, candidates: candidates)
            let items = ShepherdTemplatePlan.laying(songs, over: existing.items) { $0.mxuSourceItemId != nil }
            guard existing.items != items || existing.name != name || existing.mxuPlanVersion != version else {
                return .unchanged
            }
            let readRefs = Set(existing.items.map(\.refId))
            model.updateMainService(existing.id) { service in
                // Worked out again on the plan as the write finds it, as
                // Sunday plans are.
                let linkedSince = Set(service.items.map(\.refId)).subtracting(readRefs)
                let songs = Self.templateSongs(
                    detail, over: service.items, rules: rules, candidates: candidates, linkedSince: linkedSince)
                service.items = ShepherdTemplatePlan.laying(songs, over: service.items) { $0.mxuSourceItemId != nil }
                service.name = name
                service.serviceDate = date
                service.mxuPlanVersion = version
                service.mxuServiceTypeName = detail.serviceType.name
                service.mxuPlanTimes = times
            }
            return .updated
        }

        guard let template else { return .waiting }
        let roles = await Self.templateRoles(template, model: model)
        let id = ShepherdDayPick.serviceID(forPlan: detail.id)
        var service = model.plan(
            fromTemplate: template, id: id, date: date,
            isMessage: { roles.messages.contains($0.refId) },
            messageID: { "shepherd-message-\(detail.id)" + ($0 == 0 ? "" : "-\($0 + 1)") })
        let songs = Self.templateSongs(detail, over: [], rules: rules, candidates: candidates)
        service.items = ShepherdTemplatePlan.laying(songs, over: service.items) {
            $0.itemKind == .presentation && roles.songs.contains($0.refId)
        }
        service.name = name
        service.mxuDerivedName = name
        service.origin = ShepherdPlanSync.origin
        service.mxuPlanHexId = detail.id
        service.mxuServiceTypeName = detail.serviceType.name
        service.mxuPlanVersion = version
        service.mxuPlanTimes = times
        service.mxuSyncPaused = nil
        model.createInDrive(service)
        return .created
    }

    /// The plan's songs, linked to library songs as Sunday plans' are, each
    /// with the Shepherd header it is planned under.
    nonisolated static func templateSongs(
        _ detail: ShepherdClient.PlanDetail, over items: [ServiceItem], rules: ServiceLinkRules,
        candidates: [ServiceLinkLogic.Candidate], linkedSince: Set<String> = []
    ) -> [ShepherdTemplatePlan.Song] {
        let library = Set(candidates.map(\.id)).union(linkedSince)
        var songsOnly = detail
        songsOnly.items = detail.items.filter { $0.kind == "song" }
        let synced = ShepherdPlanSync.items(
            for: songsOnly, rules: rules, existing: items.filter { $0.mxuSourceItemId != nil },
            inLibrary: library.contains
        ) { song in librarySong(for: song, candidates: candidates) }
        let headers = ShepherdTemplatePlan.headers(of: detail)
        return synced.map { ShepherdTemplatePlan.Song(header: $0.mxuSourceItemId.flatMap { headers[$0] }, item: $0) }
    }

    /// Which of the template's presentations are songs (placeholders
    /// Shepherd's songs replace) and which are messages (each plan gets its
    /// own), by presentation id.
    private static func templateRoles(
        _ template: Service, model: AppModel
    ) async -> (songs: Set<String>, messages: Set<String>) {
        var songs: Set<String> = [], messages: Set<String> = []
        for ref in Set(template.items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }.map(\.refId)) {
            guard let presentation = try? await model.client.loadValue(Presentation.self, id: ref) else { continue }
            if presentation.presentationKind == .song { songs.insert(ref) }
            if PresentationTypes.category(of: presentation) == PresentationTypes.sermon { messages.insert(ref) }
        }
        return (songs, messages)
    }

    /// Named before plan dates were written out: "2026-11-22 — Genesis 46-47".
    static func hasNumericDateName(_ service: Service) -> Bool {
        service.name.range(of: #"^\d{4}-\d{2}-\d{2} — "#, options: .regularExpression) != nil
    }

    static func flaggedSongs(in items: [ServiceItem]) -> Int {
        items.filter { $0.itemKind == .info && $0.refId.isEmpty && $0.mxuSongTitle != nil }.count
    }

    private static func hasFlaggedSongs(_ service: Service) -> Bool { flaggedSongs(in: service.items) > 0 }

    /// A plan's items laid over a service's items. Every plan opens with the
    /// shared pre-service slideshow: Shepherd's "Pre-Service" item is linked
    /// to it, or one is put first (unless it was taken out of this plan).
    nonisolated static func planItems(
        _ detail: ShepherdClient.PlanDetail, over service: Service?, rules: ServiceLinkRules,
        candidates: [ServiceLinkLogic.Candidate], preService: String?, linkedSince: Set<String> = []
    ) -> [ServiceItem] {
        let library = Set(candidates.map(\.id)).union(linkedSince)
        let synced = ShepherdPlanSync.items(
            for: detail, rules: rules, existing: service?.items ?? [], inLibrary: library.contains
        ) { song in librarySong(for: song, candidates: candidates) }
        var probe = service ?? Service(id: "", name: "", serviceDate: "", items: [])
        // Songs put in Anthem's order by an Anthem session import stay in
        // it; Shepherd's order comes back only for songs that order lacks.
        probe.items = AnthemSessionImport.applyOrder(service?.mxuSyncedOrder, to: synced)
        return PreServiceSlides.ensuring(probe, sharedID: preService)?.items ?? synced
    }

    /// A library presentation for a plan song, by CCLI number or title.
    nonisolated private static func librarySong(
        for song: PlanFeed.Item, candidates: [ServiceLinkLogic.Candidate]
    ) -> (refId: String, arrangementId: String?)? {
        librarySong(title: song.song?.title ?? song.title, ccli: song.song?.ccliNumber, candidates: candidates)
            .map { ($0, nil) }
    }

    /// The library presentation for a song title and CCLI number, as sync
    /// links them. The Assistant uses it to link before importing.
    nonisolated static func librarySong(title: String, ccli: Int?, candidates: [ServiceLinkLogic.Candidate]) -> String? {
        var probe = ServiceItem(id: "", itemKind: .info, name: title, refId: "")
        probe.mxuSongTitle = title
        probe.mxuCcliNumber = ccli
        guard case .link(_, let refId) = ServiceLinkLogic.resolve(
            item: probe, serviceTypeName: nil, rules: ServiceLinkRules(id: "", rules: []), candidates: candidates)
        else { return nil }
        return refId
    }

    /// What sync matches songs against: every presentation's name, CCLI
    /// number and CCLI title.
    static func linkCandidates(_ model: AppModel) async -> [ServiceLinkLogic.Candidate] {
        ((try? await model.client.presentationMatchKeys()) ?? []).map {
            ServiceLinkLogic.Candidate(id: $0.id, name: $0.name, ccliNumber: $0.ccliNumber, ccliSongTitle: $0.ccliTitle)
        }
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

/// Settings › Integrations › Shepherd.
struct ShepherdSettingsForm: View {
    var model: AppModel? = nil
    @Bindable private var sync = ShepherdSync.shared
    @HotDefault(LyricImportSettings.removePunctuationKey) private var removePunctuation = true

    private var templates: [Service] {
        guard let model else { return [] }
        return model.resident.services.values.filter { $0.isTemplate == true }.sorted { $0.name < $1.name }
    }

    /// What Automatic picks now, so the choice is visible.
    private var automaticTemplateLabel: String {
        let picked = ShepherdTemplatePlan.template(
            for: sync.midweekServiceType.trimmingCharacters(in: .whitespaces), chosenID: nil, in: templates)
        return picked.map { "Automatic (\($0.name))" } ?? "Automatic (none found)"
    }

    var body: some View {
        Section {
            SecureField("API key", text: $sync.apiKey, prompt: Text("shp_…"))
                .settingsAnchor("shepherd.sync")
            TextField("Service type", text: $sync.serviceType, prompt: Text("All"))
        } header: {
            Text("Shepherd")
        } footer: {
            Text("A Shepherd admin makes the key under Connected apps, with the services:read scope. "
                + (SettingsIndex.entry("shepherd.sync")?.caption ?? ""))
        }
        Section {
            Toggle("Sundays only", isOn: $sync.sundaysOnly)
                .toggleStyle(.switch)
            LabeledContent("Load ahead") {
                Stepper("\(sync.weeksAhead) week\(sync.weeksAhead == 1 ? "" : "s")", value: $sync.weeksAhead, in: 1...12)
            }
            Toggle("Check for changes every 10 minutes", isOn: $sync.autoSync)
                .toggleStyle(.switch)
        } header: {
            Text("Plans")
        }
        Section {
            TextField("Service type", text: $sync.midweekServiceType, prompt: Text("Off"))
            Picker("Template", selection: $sync.midweekTemplateID) {
                Text(automaticTemplateLabel).tag("")
                ForEach(templates, id: \.id) { Text($0.name).tag($0.id) }
            }
        } header: {
            Text("Wednesday Night")
        } footer: {
            Text("Plans of this type are made from the template, with the songs from Shepherd in place of the template's songs. Leave the service type empty to load none.")
        }
        Section {
            Toggle("Import lyrics and chords from Shepherd automatically", isOn: $sync.importSongs)
                .toggleStyle(.switch)
                .settingsAnchor("shepherd.songs")
            Toggle("Remove punctuation from imported lyrics", isOn: $removePunctuation)
                .toggleStyle(.switch)
                .settingsAnchor("lyrics.punctuation")
        } header: {
            Text("Songs")
        } footer: {
            Text("Planned songs with no slides get them from Shepherd's chord chart, and imported songs follow chart changes. Every linked song plays the arrangement the plan chose in Shepherd, whether or not this is on. A song edited in Screens isn't replaced; it shows that Shepherd has a newer chart. Punctuation removal applies to every lyrics import. Songs already in the library don't change.")
        }
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Test Key") { Task { await sync.testConnection() } }
                        .disabled(!sync.isConfigured)
                    Button(sync.isSyncing ? "Loading…" : "Load Plans Now") { Task { await sync.sync() } }
                        .disabled(!sync.isConfigured || sync.isSyncing)
                }
            } label: {
                if let app = sync.connectedApp {
                    Text("Connected as “\(app)”")
                } else {
                    Text(sync.isConfigured ? "Not checked yet" : "No key")
                }
                if let summary = sync.lastSummary, let when = sync.lastSync {
                    Text("\(summary) · \(when.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = sync.lastError {
                Text(error).font(.subheadline).foregroundStyle(.red)
            }
        }
    }
}
