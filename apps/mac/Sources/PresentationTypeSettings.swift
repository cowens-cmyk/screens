import PresenterCore
import SwiftUI

/// Settings › Stage › Presentation Types: default actions per type, run
/// whenever a presentation of that type goes live. One form row per type.
struct PresentationTypeRulesForm: View {
    let model: AppModel
    @State private var editing: String?

    var body: some View {
        Group {
            ForEach(PresentationTypes.builtIn, id: \.self) { category in
                LabeledContent(category) {
                    HStack(spacing: 12) {
                        let count = actions(for: category).count
                        Text(count == 0 ? "No actions" : "\(count) action\(count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Button("Edit…") { editing = category }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { editing.map(Editing.init) }, set: { editing = $0?.id })) { target in
            SlideActionsSheet(
                model: model,
                slideName: "\(target.id) Presentations",
                actions: Binding(
                    get: { actions(for: target.id) },
                    set: { setActions($0, for: target.id) }
                )
            )
        }
    }

    private struct Editing: Identifiable { let id: String }

    private func actions(for category: String) -> [SlideAction] {
        model.slideBuilding.presentationTypeRules?.first { $0.category == category }?.actions ?? []
    }

    private func setActions(_ actions: [SlideAction], for category: String) {
        model.updateSlideBuilding { settings in
            var rules = settings.presentationTypeRules ?? []
            rules.removeAll { $0.category == category }
            if !actions.isEmpty { rules.append(PresentationTypeRule(category: category, actions: actions)) }
            settings.presentationTypeRules = rules.isEmpty ? nil : rules
        }
    }
}
