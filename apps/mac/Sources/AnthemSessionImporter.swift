import AppKit
import Observation
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// Imports the week's setlist from an Anthem session file (`Sunday.anthem`,
/// the file the band moves sessions between Macs with), for when Anthem
/// isn't on this Mac's network or isn't running yet. The file is dropped on
/// a plan, opened from File › Import Anthem Session…, or opened with
/// Screens from the Finder.
///
/// It does what following Anthem over the network does, at once, for one
/// plan: the songs take Anthem's order (kept through Shepherd syncs, see
/// AnthemSessionImport), Anthem's songs the plan lacks are added, songs with
/// no slides get lyrics (a library copy, else Shepherd, as Build Sunday
/// does), and each song gets Anthem's section order (Match Anthem). The
/// file has no lyrics; a song neither the library nor Shepherd has stays
/// flagged with Get Lyrics.
@MainActor
@Observable
final class AnthemSessionImporter {
    static let shared = AnthemSessionImporter()

    struct Pending: Identifiable {
        let id = UUID()
        let fileName: String
        let setlists: [AnthemSessionFile.SetlistInfo]
        /// The plan it was dropped on.
        let planID: String?
    }

    var pending: Pending?
    var failure: String?

    static func accepts(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == AnthemSessionFile.fileExtension
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: AnthemSessionFile.fileExtension) ?? .data]
        panel.message = "Choose an Anthem session file"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url, planID: nil) }
        }
    }

    func open(_ url: URL, planID: String?) {
        Task { @MainActor in
            // Only the JSON is read, but the file may be on a slow drive.
            let result = await Task.detached { () -> Result<[AnthemSessionFile.SetlistInfo], any Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try AnthemSessionFile.read(url) }
            }.value
            switch result {
            case .success(let setlists) where setlists.contains(where: { !$0.setlist.entries.isEmpty }):
                pending = Pending(fileName: url.lastPathComponent,
                                  setlists: setlists.filter { !$0.setlist.entries.isEmpty }, planID: planID)
            case .success:
                failure = "\(url.lastPathComponent) has no songs in its setlists."
            case .failure(let error):
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Matching

    /// The plan's songs, as Anthem's feed compares them; nil while one is
    /// still loading.
    static func planSongs(_ service: Service, model: AppModel) -> [AnthemSongMatch.PlanSong]? {
        var warming = false
        let songs = service.items.compactMap { item -> AnthemSongMatch.PlanSong? in
            let presentation = item.itemKind == .presentation ? model.presentation(item.refId) : nil
            if item.itemKind == .presentation, presentation == nil { warming = true }
            guard AnthemSongMatch.PlanSong.isSong(item, presentation: presentation) else { return nil }
            return AnthemSongMatch.PlanSong(item: item, presentation: presentation)
        }
        return warming ? nil : songs
    }

    static func report(_ setlist: AnthemShow.Setlist, service: Service, model: AppModel) -> AnthemSongMatch.Report? {
        planSongs(service, model: model).map {
            AnthemSongMatch.report(setlist: setlist, songs: $0,
                                   options: .init(ignoreInstrumental: AnthemFeed.shared.ignoreInstrumental))
        }
    }

    /// The report once every song has loaded, waiting up to a few seconds.
    static func settledReport(_ setlist: AnthemShow.Setlist, serviceID: String, model: AppModel) async -> AnthemSongMatch.Report? {
        for _ in 0..<20 {
            guard let service = try? model.service(serviceID) else { return nil }
            if let report = report(setlist, service: service, model: model) { return report }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func targetPlan(for info: AnthemSessionFile.SetlistInfo, model: AppModel) -> String? {
        AnthemSessionImport.targetPlan(
            for: info, plans: Array(model.resident.services.values), today: AppModel.isoDate(.now)
        ) { service in
            report(info.setlist, service: service, model: model)?.followsSetlist(isCurrentOrNext: true) ?? false
        }?.id
    }

    // MARK: Importing

    /// Puts the setlist into the plan and says what it did, a line a step.
    func run(_ setlist: AnthemShow.Setlist, intoPlan serviceID: String, model: AppModel) async -> [String] {
        guard let report = await Self.settledReport(setlist, serviceID: serviceID, model: model),
              let service = try? model.service(serviceID) else {
            return ["The plan's songs didn't load. Try again."]
        }
        var lines: [String] = []

        // 1. Anthem's order, and Anthem's songs the plan doesn't have.
        var pairs: [String: String] = [:]
        for result in report.results {
            if let entry = result.entryID, let item = result.itemID { pairs[entry] = item }
        }
        let arranged = AnthemSessionImport.arrange(items: service.items, setlist: setlist, pairs: pairs)
        if arranged.items != service.items {
            let addedIDs = arranged.added.map(\.id)
            let pairs = pairs
            model.updateService(serviceID) { plan in
                var ids = addedIDs.makeIterator()
                plan.items = AnthemSessionImport.arrange(
                    items: plan.items, setlist: setlist, pairs: pairs,
                    newID: { ids.next() ?? UUID().uuidString }).items
            }
        }
        // Main, so Shepherd sync (which works from main) keeps the order.
        let order = arranged.songOrder
        model.updateMainService(serviceID) { $0.mxuSyncedOrder = order }
        if arranged.moved > 0 { lines.append("Put \(count(arranged.moved, "song")) in Anthem's order.") }
        if !arranged.added.isEmpty {
            lines.append("Added \(arranged.added.map(\.name).joined(separator: ", ")).")
        }

        // 2. Lyrics for Anthem's songs with no slides.
        let anthemItems = Set(pairs.values).union(arranged.added.map(\.id))
        let plan = (try? model.service(serviceID)) ?? service
        let targets = SundayPrep.songsWithoutSlides(in: plan).filter { anthemItems.contains($0.id) }
        var fromLibrary = 0, fromShepherd = 0
        var stillMissing: [String] = []
        if !targets.isEmpty {
            let candidates = await ShepherdSync.linkCandidates(model)
            for item in targets {
                let title = item.mxuSongTitle ?? item.name
                if let ref = ShepherdSync.librarySong(title: title, ccli: item.mxuCcliNumber, candidates: candidates) {
                    if LyricsFetcher.shared.link(item.id, planID: serviceID, to: ref, model: model) { fromLibrary += 1 }
                    continue
                }
                guard ShepherdSync.shared.isConfigured else { stillMissing.append(title); continue }
                switch await LyricsFetcher.importFromShepherd(item: item, title: title, planID: serviceID, model: model) {
                case .imported: fromShepherd += 1
                case .alreadyLinked: break
                default: stillMissing.append(title)
                }
            }
        }
        if fromLibrary > 0 { lines.append("Linked \(count(fromLibrary, "song")) already in the library.") }
        if fromShepherd > 0 { lines.append("Imported lyrics for \(count(fromShepherd, "song")) from Shepherd.") }
        if !stillMissing.isEmpty {
            lines.append("No lyrics for \(stillMissing.joined(separator: ", ")). Use Get Lyrics in the plan.")
        }

        // 3. Anthem's section order on every song that plays it differently.
        var matched = 0
        var missingSections: [String] = []
        if let after = await Self.settledReport(setlist, serviceID: serviceID, model: model) {
            for result in after.results {
                guard let itemID = result.itemID, let comparison = result.comparison else { continue }
                if result.status == .mismatch, !comparison.proposed.isEmpty,
                   model.matchAnthem(serviceID: serviceID, itemID: itemID, order: comparison.proposed) {
                    matched += 1
                }
                if !comparison.missing.isEmpty {
                    missingSections.append("\(result.title) has no \(comparison.missing.map(\.display).joined(separator: ", "))")
                }
            }
        }
        if matched > 0 { lines.append("Set Anthem's section order on \(count(matched, "song")).") }
        if !missingSections.isEmpty {
            lines.append("Add in the song editor: \(missingSections.joined(separator: "; ")).")
        }

        // The plan's marks follow this setlist until Anthem is on the network.
        AnthemFeed.shared.useSetlist(fromFile: setlist)
        if lines.isEmpty { lines.append("The plan already matches Anthem's setlist.") }
        model.noteImportSummary(lines.joined(separator: " "))
        return lines
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Shows what the file holds and the plan it goes into before anything
/// changes, then what was done.
struct AnthemSessionImportSheet: View {
    let model: AppModel
    let pending: AnthemSessionImporter.Pending
    @Environment(\.dismiss) private var dismiss
    @State private var setlistIndex = 0
    @State private var planID: String?
    @State private var running = false
    @State private var done: [String]?

    private var info: AnthemSessionFile.SetlistInfo { pending.setlists[setlistIndex] }

    private var plans: [Service] {
        let today = AppModel.isoDate(.now)
        return model.resident.services.values
            .filter { $0.isTemplate != true && (String($0.serviceDate.prefix(10)) >= today || $0.id == planID) }
            .sorted { ($0.serviceDate, $0.name, $0.id) < ($1.serviceDate, $1.name, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Anthem Session").font(.title3.weight(.semibold))
            Text(pending.fileName).font(.caption).foregroundStyle(.secondary)
            if let done {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(done, id: \.self) { Label($0, systemImage: "checkmark").labelStyle(.titleAndIcon) }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                form
            }
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small); Text("Importing…").foregroundStyle(.secondary) }
                Spacer()
                if done != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Import") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(planID == nil || running)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { choosePlan() }
        .onChange(of: setlistIndex) { _, _ in choosePlan() }
    }

    @ViewBuilder
    private var form: some View {
        if pending.setlists.count > 1 {
            Picker("Setlist", selection: $setlistIndex) {
                ForEach(pending.setlists.indices, id: \.self) { Text(pending.setlists[$0].setlist.name).tag($0) }
            }
        }
        Picker("Plan", selection: $planID) {
            if planID == nil { Text("Choose a plan").tag(String?.none) }
            ForEach(plans, id: \.id) { plan in
                Text("\(plan.name) · \(AppModel.anthemPlanLabel(plan))").tag(Optional(plan.id))
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(info.setlist.entries.enumerated()), id: \.offset) { index, entry in
                    row(index + 1, entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(260, CGFloat(info.setlist.entries.count) * 40 + 8))
        Text("Songs go in Anthem's order and play its section order. Songs with no slides get lyrics from the library or Shepherd.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ number: Int, _ entry: AnthemShow.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    if let key = entry.key { Text(key).font(.caption).foregroundStyle(.secondary) }
                    if !inPlan(entry) {
                        Text("Not in plan · will be added").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let sections = entry.arrangement?.sections, !sections.isEmpty {
                    Text(sections.map(\.name).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    private func inPlan(_ entry: AnthemShow.Entry) -> Bool {
        guard let planID, let service = try? model.service(planID),
              let report = AnthemSessionImporter.report(info.setlist, service: service, model: model)
        else { return true }
        return report.results.contains { $0.entryID == entry.entryId && $0.itemID != nil }
    }

    private func choosePlan() {
        if setlistIndex == 0, let dropped = pending.planID {
            planID = dropped
        } else {
            planID = AnthemSessionImporter.targetPlan(for: info, model: model)
        }
    }

    private func start() {
        guard let planID else { return }
        running = true
        let setlist = info.setlist
        Task {
            let lines = await AnthemSessionImporter.shared.run(setlist, intoPlan: planID, model: model)
            model.currentServiceID = planID
            running = false
            done = lines
        }
    }
}

/// The import sheet and its error, on the main window.
struct AnthemSessionImportPresenter: ViewModifier {
    let model: AppModel
    @Bindable private var importer = AnthemSessionImporter.shared

    init(model: AppModel) { self.model = model }

    func body(content: Content) -> some View {
        content
            .sheet(item: $importer.pending) { pending in
                AnthemSessionImportSheet(model: model, pending: pending)
            }
            .alert("Can't Import Anthem Session", isPresented: Binding(
                get: { importer.failure != nil }, set: { if !$0 { importer.failure = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(importer.failure ?? "")
            }
    }
}
