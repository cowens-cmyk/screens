import Foundation

/// The ProPresenter API shapes Screens answers with, so apps that drive
/// ProPresenter's slides over the network (Anthem) can drive Screens.
public enum ProPresenterCompat {
    /// Slides grouped by section, in the presentation's own order: trigger
    /// index N is the presentation's slide N.
    public static func describe(_ presentation: Presentation) -> [String: Any] {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        var groups: [[String: Any]] = []
        var current: (section: String?, slides: [[String: Any]])?
        for slide in presentation.slides {
            let text = slide.objects.first { $0.objectKind == .text }?.text ?? ""
            let entry: [String: Any] = ["text": text, "label": slide.name, "enabled": true]
            if let open = current, open.section == slide.sectionId {
                current?.slides.append(entry)
            } else {
                if let open = current {
                    groups.append(["name": open.section.flatMap { names[$0] } ?? "", "slides": open.slides])
                }
                current = (slide.sectionId, [entry])
            }
        }
        if let open = current {
            groups.append(["name": open.section.flatMap { names[$0] } ?? "", "slides": open.slides])
        }
        return ["id": ["uuid": presentation.id, "name": presentation.name, "index": 0], "groups": groups]
    }

}
