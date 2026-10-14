import AppKit
import PresenterCore
import UniformTypeIdentifiers

/// File › Export and File › Import for one presentation or theme, carrying
/// its media, fonts, stage layouts, macros and timers to another Mac.
@MainActor
struct ShareTransferRunner {
    let model: AppModel

    static var fileTypes: [UTType] {
        [ShareBundle.presentationExtension, ShareBundle.themeExtension].compactMap { UTType(filenameExtension: $0) }
    }

    func presentExport(kind: DocumentKind, id: String, name: String) {
        let panel = NSSavePanel()
        let ext = kind == .theme ? ShareBundle.themeExtension : ShareBundle.presentationExtension
        panel.nameFieldStringValue = "\(name.replacingOccurrences(of: "/", with: "-")).\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await export(kind: kind, id: id, name: name, to: url) }
        }
    }

    func export(kind: DocumentKind, id: String, name: String, to url: URL) async {
        let activity = ImportActivityModel(title: kind == .theme ? "Export Theme" : "Export Presentation")
        activity.finishedHeadline = "Exported “\(name)”"
        activity.emptyHeadline = "“\(name)” could not be exported."
        ImportActivityWindow.present(activity)
        let root = model.client.rootURL
        do {
            // Timers live in this Mac's settings, so the ones the slides
            // start are written out alongside the documents.
            let strings = try await ShareBundle.collect(root: root, kind: kind, id: id).strings
            var extra: [String: Data] = [:]
            if let timers = TimersController.current?.sharedConfigs(ids: strings) {
                extra[ShareBundle.timersName] = timers
            }
            let contents = try await ShareBundle.export(
                root: root, kind: kind, id: id, name: name, extraFiles: extra, to: url)
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
        panel.message = "Choose a Screens theme or presentation"
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
            var options = BackupImportOptions()
            options.excluded = [.settings]
            let result = try await BackupBundle.restore(
                from: folder, into: model.client, options: options) { activity.apply($0) }
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
            let section: LibrarySection = info.kind == DocumentKind.theme.rawValue ? .themes : .presentations
            model.selectedSection = section
            model.selectedEntryID = info.id
            model.libraryRevealID = info.id
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
