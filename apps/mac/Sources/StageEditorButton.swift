import PresenterCore
import SwiftUI

/// Opens the stage layout for the current stage mode in the editor — the
/// worship layout for Worship (and Mirror, which has no layout of its own),
/// the message layout for Message. Creates it from its template the first
/// time.
struct StageEditorButton: View {
    let model: AppModel
    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    var body: some View {
        Button(action: open) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Edit the stage display")
        }
        .buttonStyle(.plain)
        .help("Edit the stage display")
    }

    private func open() {
        if let id = Self.open(model: model) { show(id) }
    }

    /// The current stage mode's layout, created from its template the first
    /// time; nil until the library has loaded (then try again).
    @discardableResult
    static func open(model: AppModel, then show: ((String) -> Void)? = nil) -> String? {
        let id = StageLayouts.id(for: ShowSetup.shared.stageMode)
        if model.indexEntry(id) != nil {
            show?(id)
            return id
        }
        // Not until the library has loaded: an id that just hasn't been read
        // yet must not be created a second time.
        guard model.client.isReady else { return nil }
        let created = model.createInDrive(StageLayouts.make(id))
        if model.libraryEntry(id) != nil {
            show?(id)
            return id
        }
        Task { @MainActor in
            _ = try? await created.value
            show?(id)
        }
        return nil
    }

    private func show(_ id: String) {
        model.openInEditor(entryID: id)
        appModeRaw = AppMode.edit.rawValue
    }
}
