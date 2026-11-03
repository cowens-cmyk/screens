import Foundation

public extension Library {

    /// Slides that carry their own Cut follow the room default instead.
    /// ProPresenter writes a Cut (or "None") on every slide, and the import
    /// kept it as the slide's own choice, which beat the room's dissolve on
    /// every song brought over. While Cut was the room default nobody had a
    /// reason to set it on a slide, so these are all from the import.
    ///
    /// Songs the import ledger had as unedited are stamped again, or the
    /// next ProPresenter re-import would skip every one of them as edited.
    /// It runs as the library opens, so a presentation that can't be read
    /// or saved is reported to `failed` and passed over rather than keeping
    /// the library shut.
    @discardableResult
    func migrateImportedCutTransitions(
        failed: (_ presentationID: String, _ error: any Error) -> Void = { _, _ in }
    ) throws -> Int {
        var migrated = 0
        var ledger = (try? store.load(ImportLedger.self, id: ImportLedger.wellKnownID))?.value
            ?? ImportLedger(id: ImportLedger.wellKnownID, entries: [])
        var ledgerDirty = false
        for id in try store.ids(of: .presentation) {
            do {
                let document = try open(Presentation.self, id: id)
                guard document.value.slides.contains(where: { $0.transition?.transitionKind == .cut }) else { continue }
                let preHash = ImportFingerprint.hash(document.value)
                try document.update { presentation in
                    for index in presentation.slides.indices
                    where presentation.slides[index].transition?.transitionKind == .cut {
                        presentation.slides[index].transition = nil
                    }
                }
                try save(document)
                migrated += 1
                if let preHash, ledger.value(for: id) == preHash,
                   let stored = try? open(Presentation.self, id: id).value,
                   let postHash = ImportFingerprint.hash(stored) {
                    ledger.stamp(id, postHash)
                    ledgerDirty = true
                }
            } catch {
                failed(id, error)
            }
        }
        if ledgerDirty {
            let entries = ledger.entries
            if let document = try? store.load(ImportLedger.self, id: ImportLedger.wellKnownID) {
                try? document.update { $0.entries = entries }
                try? store.save(document)
            } else {
                try? store.save(TypedDocument(ledger))
            }
        }
        return migrated
    }
}
