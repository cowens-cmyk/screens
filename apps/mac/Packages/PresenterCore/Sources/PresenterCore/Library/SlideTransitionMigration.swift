import Foundation

public extension Library {

    /// Slides that carry their own Cut follow the room default instead.
    /// ProPresenter writes a Cut (or "None") on every slide, and the import
    /// kept it as the slide's own choice, which beat the room's dissolve on
    /// every song brought over. While Cut was the room default nobody had a
    /// reason to set it on a slide, so these are all from the import.
    @discardableResult
    func migrateImportedCutTransitions() throws -> Int {
        var migrated = 0
        for id in try store.ids(of: .presentation) {
            let document = try open(Presentation.self, id: id)
            guard document.value.slides.contains(where: { $0.transition?.transitionKind == .cut }) else { continue }
            try document.update { presentation in
                for index in presentation.slides.indices
                where presentation.slides[index].transition?.transitionKind == .cut {
                    presentation.slides[index].transition = nil
                }
            }
            try save(document)
            migrated += 1
        }
        return migrated
    }
}
