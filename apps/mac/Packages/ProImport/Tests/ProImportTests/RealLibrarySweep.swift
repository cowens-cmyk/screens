import Foundation
import Testing
import PresenterCore
@testable import ProImport

/// Imports real .pro files from PRO_IMPORT_FILES into a scratch library and
/// prints what landed. Skipped unless the variable is set.
@MainActor
struct RealLibrarySweep {
    @Test func proFiles() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PRO_IMPORT_FILES"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try ProPresenterImporter(client: await started(library))
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { ["pro", "probundle"].contains($0.pathExtension) }
        let summaries = await importer.importItems(at: urls)
        var imported = 0
        for s in summaries {
            if let id = s.presentationID {
                imported += 1
                let p = try await library.open(Presentation.self, id: id).value
                print("OK \(s.name): slides=\(p.slides.count) sections=\(p.sections?.count ?? 0) warnings=\(s.warnings.count)")
            } else {
                print("SKIPPED \(s.name): \(String(describing: s.skipped)) \(s.warnings.prefix(2))")
            }
        }
        print("IMPORTED \(imported) of \(urls.count)")
        #expect(imported > 0)
    }
}
