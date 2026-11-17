import AppKit
import PresenterCore
import UniformTypeIdentifiers

/// File › Export and File › Import for one presentation, theme or plan,
/// carrying its media, fonts, stage layouts, macros and timers to another
/// Mac. A plan file holds the plan and everything in it, so the other Mac
/// gets the same plan, ready to run.
@MainActor
struct ShareTransferRunner {
    let model: AppModel

    static var fileTypes: [UTType] {
        [ShareBundle.presentationExtension, ShareBundle.themeExtension, ShareBundle.planExtension]
            .compactMap { UTType(filenameExtension: $0) }
    }

    func presentExport(kind: DocumentKind, id: String, name: String) {
        let panel = NSSavePanel()
        let ext = Self.fileExtension(for: kind)
        panel.nameFieldStringValue = "\(ScreensFolder.fileName(name)).\(ext)"
        panel.directoryURL = ScreensFolder.exports
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await export(kind: kind, id: id, name: name, to: url) }
        }
    }

    /// What every exported file carries besides its own documents: the
    /// look (ShareLook) as look.json, and the ids it names, so the stage
    /// displays and the themes and media of the Worship settings go too.
    static func lookExtras(_ model: AppModel) -> (files: [String: Data], ids: [String]) {
        let look = ShareLook(model.slideBuilding)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = look.isEmpty ? nil : try? encoder.encode(look)
        return (data.map { [ShareLook.fileName: $0] } ?? [:], look.referencedIDs)
    }

    static func fileExtension(for kind: DocumentKind) -> String {
        switch kind {
        case .theme: ShareBundle.themeExtension
        case .service: ShareBundle.planExtension
        default: ShareBundle.presentationExtension
        }
    }

    func export(kind: DocumentKind, id: String, name: String, to url: URL) async {
        let activity = ImportActivityModel(
            title: kind == .theme ? "Export Theme" : kind == .service ? "Export Plan" : "Export Presentation")
        activity.finishedHeadline = "Exported “\(name)”"
        activity.emptyHeadline = "“\(name)” could not be exported."
        ImportActivityWindow.present(activity)
        let root = model.client.rootURL
        do {
            // Timers live in this Mac's settings, so the ones the slides
            // start are written out alongside the documents.
            let strings = try await ShareBundle.collect(root: root, kind: kind, id: id).strings
            let look = Self.lookExtras(model)
            var extra = look.files
            if let timers = TimersController.current?.sharedConfigs(ids: strings) {
                extra[ShareBundle.timersName] = timers
            }
            let contents = try await ShareBundle.export(
                root: root, kind: kind, id: id, name: name, extraFiles: extra, alsoIDs: look.ids, to: url)
            var lines = ["\(contents.count) documents"]
            let media = (contents.documents[.media]?.count ?? 0) + (contents.documents[.audio]?.count ?? 0)
            if media > 0 { lines.append("\(media) media files") }
            let fonts = ShareBundle.fontURLs(for: contents.fontNames).count
            if fonts > 0 { lines.append("\(fonts) font files") }
            if extra[ShareBundle.timersName] != nil { lines.append("Timers its actions use") }
            lines.append("Saved to \(url.path)")
            activity.finish(summaryLines: lines, warnings: [])
        } catch {
            activity.finish(summaryLines: [], warnings: [error.localizedDescription])
        }
    }

    func presentImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.fileTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose a Screens theme, presentation or plan"
        panel.directoryURL = ScreensFolder.made(ScreensFolder.root)
        panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { await importFile(url) }
            }
        }
    }

    func importFile(_ url: URL) async {
        let activity = ImportActivityModel(title: "Import \(url.deletingPathExtension().lastPathComponent)")
        activity.finishedHeadline = "Imported “\(url.deletingPathExtension().lastPathComponent)”"
        activity.emptyHeadline = "That file could not be imported."
        ImportActivityWindow.present(activity)
        do {
            let (folder, info) = try ShareBundle.unpack(url)
            defer { try? FileManager.default.removeItem(at: folder) }
            // Everything but the stage displays merges in; settings stay
            // this Mac's own.
            var options = BackupImportOptions()
            options.excluded = [.settings, .confidenceLayouts]
            let result = try await BackupBundle.restore(
                from: folder, into: model.client, options: options) { activity.apply($0) }
            // The stage displays come in as the sender has them (every
            // library has the same ones, so merging would mix the two).
            var layouts = BackupImportOptions()
            layouts.policy = .replace
            layouts.excluded = Set(BackupSection.allCases).subtracting([.confidenceLayouts])
            _ = try? await BackupBundle.restore(from: folder, into: model.client, options: layouts)
            // The Worship look fills in only what this Mac hasn't chosen.
            if let data = try? Data(contentsOf: folder.appendingPathComponent(ShareLook.fileName)),
               let look = try? JSONDecoder().decode(ShareLook.self, from: data),
               look.filling(model.slideBuilding) != nil {
                model.updateSlideBuilding { settings in
                    if let filled = look.filling(settings) { settings = filled }
                }
            }
            if result.fontsCopied > 0 {
                FontActivator.activateStored(libraryRoot: model.client.rootURL)
            }
            var lines = BackupTransferRunner.summaryLines(result)
            let installed = Self.installFonts(from: folder.appendingPathComponent("fonts", isDirectory: true))
            if installed > 0 { lines.append("\(installed) fonts installed on this Mac") }
            if let data = try? Data(contentsOf: folder.appendingPathComponent(ShareBundle.timersName)),
               let added = TimersController.current?.adoptShared(data), added > 0 {
                lines.append("\(added) timers")
            }
            model.noteExternalMutation()
            if result.merged + result.replaced > 0 { model.noteImportReplacedDocuments() }
            if info.kind == DocumentKind.service.rawValue {
                // A plan opens, ready to run.
                model.currentServiceID = info.id
            } else {
                let section: LibrarySection = info.kind == DocumentKind.theme.rawValue ? .themes : .presentations
                model.selectedSection = section
                model.selectedEntryID = info.id
                model.libraryRevealID = info.id
            }
            activity.finish(summaryLines: lines, warnings: result.warnings)
        } catch {
            activity.finish(summaryLines: [], warnings: [error.localizedDescription])
        }
    }

    /// Fonts also go in ~/Library/Fonts, so they're installed for every app
    /// (Screens has them already from its library).
    private static func installFonts(from folder: URL) -> Int {
        let files = FileManager.default
        guard let fonts = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let userFonts = files.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Fonts", isDirectory: true)
        else { return 0 }
        try? files.createDirectory(at: userFonts, withIntermediateDirectories: true)
        let present = Set(((try? files.contentsOfDirectory(atPath: userFonts.path)) ?? []).map { $0.lowercased() })
        var installed = 0
        for font in fonts where !present.contains(font.lastPathComponent.lowercased()) {
            if (try? files.copyItem(at: font, to: userFonts.appendingPathComponent(font.lastPathComponent))) != nil {
                installed += 1
            }
        }
        return installed
    }
}

/// Files opened from Finder before or after the library is ready.
@MainActor
enum ShareOpenQueue {
    static var model: AppModel? {
        didSet { flush() }
    }
    private static var pending: [URL] = []

    static func open(_ urls: [URL]) {
        let kinds = [ShareBundle.themeExtension, ShareBundle.presentationExtension, ShareBundle.planExtension]
        pending += urls.filter { kinds.contains($0.pathExtension.lowercased()) || AnthemSessionImporter.accepts($0) }
        flush()
    }

    private static func flush() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        model.whenLibraryReady {
            Task { @MainActor in
                for url in urls {
                    if AnthemSessionImporter.accepts(url) {
                        AnthemSessionImporter.shared.open(url, planID: nil)
                    } else {
                        await ShareTransferRunner(model: model).importFile(url)
                    }
                }
            }
        }
    }
}
