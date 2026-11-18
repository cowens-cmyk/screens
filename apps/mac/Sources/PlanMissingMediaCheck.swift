import AppKit
import PresenterCore
import SwiftUI

/// When a plan is opened, Screens looks through everything in it (each
/// item's presentation, its media and audio, every version) for media whose
/// file isn't on this Mac or that was deleted, and says so straight away in
/// a sheet, so it's found and fixed before the service rather than when a
/// cue goes up black. See PlanMissingMedia.
extension AppModel {
    func planMissingMedia(_ planID: String) async -> [PlanMissingMedia.Finding] {
        guard let plan = resident.services.value(planID) else { return [] }
        let deckIDs = PlanMissingMedia.presentationIDs(in: plan)
        var deckMedia: [String: Set<String>] = [:]
        if !deckIDs.isEmpty, let reader = try? await client.reader() {
            deckMedia = await reader.loadValues(
                Presentation.self, ids: deckIDs, priority: .userInitiated
            ) { MediaReferences.ids(in: $0) }.values
        }
        let uses = PlanMissingMedia.uses(
            of: plan, presentationMedia: { deckMedia[$0] }, playlist: { try? self.playlist($0) })
        let blobs = blobs
        return PlanMissingMedia.findings(
            uses: uses,
            media: { self.media($0) },
            audio: { self.audio($0) },
            fileExists: { blobs?.url(forHash: $0) != nil },
            deletedName: { self.posterStore?.tombstone(id: $0)?.name })
    }

    /// Puts a new file behind a song in the Audio library whose file is
    /// missing; nil when the file can't be read.
    func replaceAudioFile(_ id: String, with url: URL) async -> [String]? {
        guard let blobs, audio(id) != nil,
              let hash = await Task.detached(priority: .userInitiated, operation: {
                  try? blobs.store(fileURL: url)
              }).value
        else { return nil }
        updateAudio(id) {
            $0.fileHash = hash
            $0.fileName = url.lastPathComponent
        }
        noteBlobsChanged()
        return []
    }

    /// The findings last shown for each plan this launch, so reopening a
    /// plan doesn't ask again unless something else has gone missing.
    func shouldShowMissingMedia(_ findings: [PlanMissingMedia.Finding], planID: String) -> Bool {
        guard !findings.isEmpty else { return false }
        let stamp = PlanMissingMedia.stamp(findings)
        guard missingMediaShown[planID] != stamp else { return false }
        missingMediaShown[planID] = stamp
        return true
    }
}

/// Opens the sheet when a plan is opened and has missing media. Waits a
/// moment first: a plan that just synced may still be downloading its files,
/// and those that arrive aren't missing.
struct PlanMissingMediaPrompt: ViewModifier {
    let model: AppModel
    @State private var shown: IdentifiedID?

    func body(content: Content) -> some View {
        content
            .task(id: model.currentServiceID) {
                guard let planID = model.currentServiceID else { return }
                try? await Task.sleep(for: .seconds(1.5))
                // Up to 20 seconds more while files are coming down.
                for _ in 0..<20 where CloudSync.shared.files.downloading > 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled, model.currentServiceID == planID else { return }
                let findings = await model.planMissingMedia(planID)
                guard !Task.isCancelled, model.currentServiceID == planID else { return }
                if model.shouldShowMissingMedia(findings, planID: planID) {
                    shown = IdentifiedID(id: planID)
                }
            }
            .sheet(item: $shown) { plan in
                PlanMissingMediaSheet(model: model, planID: plan.id)
            }
    }
}

struct PlanMissingMediaSheet: View {
    let model: AppModel
    let planID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.runOnly) private var runOnly

    @State private var findings: [PlanMissingMedia.Finding] = []
    @State private var loaded = false
    @State private var scanning = false
    @State private var scanSummary: String?

    private var planName: String {
        model.resident.services.value(planID)?.name ?? "This plan"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(findings.isEmpty && loaded ? "Nothing is missing now" : title)
                        .font(.title3.weight(.semibold))
                    Text("\(planName) uses media that can't play on this Mac. Until it's found, those cues show black.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = situationNote {
                Text(note)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle.standard(CornerStandard.element))
            }
            List {
                ForEach(findings) { finding in
                    row(finding)
                }
            }
            .frame(minHeight: 160)
            HStack(spacing: 10) {
                if !runOnly {
                    Button("Find in a Folder…") { scanFolder() }
                        .disabled(scanning || findings.isEmpty)
                        .help("Pick a folder (Downloads, a backup, a drive) and Screens puts back every file it finds there that matches exactly, whatever it's named.")
                }
                if scanning { ProgressView().controlSize(.small) }
                if let scanSummary {
                    Text(scanSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .task { await refresh() }
        .onChange(of: model.blobsVersion) { _, _ in Task { await refresh() } }
    }

    private var title: String {
        findings.count == 1 ? "1 piece of media is missing" : "\(findings.count) pieces of media are missing"
    }

    /// Why things may be missing, when Screens can tell: the media drive
    /// unplugged, or files still downloading from the church library.
    private var situationNote: String? {
        if case .external(let folder) = MediaStorage.location(), !MediaStorage.isReachable(folder) {
            return "The media drive isn't connected (\(folder.path)). Plug it in and these come back."
        }
        let downloading = CloudSync.shared.files.downloading
        if downloading > 0 {
            return "Still downloading \(downloading) file\(downloading == 1 ? "" : "s") from the church library. Each one drops off this list when it arrives."
        }
        return nil
    }

    @ViewBuilder
    private func row(_ finding: PlanMissingMedia.Finding) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name)
                Text(detail(finding))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Deleted music can't be put back from here: the plan item
            // needs a new song from the Audio library.
            if !runOnly, !(finding.isAudio && finding.problem == .deleted) {
                Button("Choose File…") { chooseFile(for: finding) }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ finding: PlanMissingMedia.Finding) -> String {
        let why = finding.problem == .deleted ? "Deleted from the library" : "File not on this Mac"
        return "\(why) · used in \(finding.usedIn.joined(separator: ", "))"
    }

    private func refresh() async {
        findings = await model.planMissingMedia(planID)
        loaded = true
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Search"
        panel.message = "Screens looks in this folder and the folders inside it for exact copies of the missing files."
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            scanning = true
            Task { @MainActor in
                let result = await model.locateMissingMedia(in: folder)
                scanning = false
                let total = result.relinked + result.restored
                scanSummary = total == 0 ? "No exact copies there." : "Found \(total)."
                await refresh()
            }
        }
    }

    private func chooseFile(for finding: PlanMissingMedia.Finding) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = finding.isAudio ? [.audio] : [.image, .movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let carried: [String]?
                if finding.problem == .deleted {
                    carried = await model.restoreMediaReference(id: finding.mediaID, suggestedName: finding.name, with: url)
                } else if finding.isAudio {
                    carried = await model.replaceAudioFile(finding.mediaID, with: url)
                } else {
                    carried = await model.replaceMediaFile(finding.mediaID, with: url)
                }
                if let carried {
                    MediaRelinkAlerts.carriedSettingsWarning(itemName: finding.name, carried: carried)
                }
                await refresh()
            }
        }
    }
}
