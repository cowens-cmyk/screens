import Foundation

/// Presentation types ("Worship", "Sermon", "Bible"…) carry default actions
/// that run whenever a presentation of that type goes live — switch the stage
/// layout, start the sermon timer, change to the Bible lower-third look —
/// without copying actions onto every slide.
public enum PresentationTypes {
    public static let worship = "Worship"
    public static let sermon = "Sermon"
    public static let bible = "Bible"
    public static let announcements = "Announcements"
    public static let video = "Video"

    public static let builtIn = [worship, sermon, bible, announcements, video]

    /// Songs count as Worship unless they say otherwise.
    public static func category(of presentation: Presentation) -> String? {
        if let category = presentation.category, !category.isEmpty { return category }
        return presentation.presentationKind == .song ? worship : nil
    }

    public static func actions(for presentation: Presentation, rules: [PresentationTypeRule]?) -> [SlideAction] {
        guard let category = category(of: presentation) else { return [] }
        return rules?.first { $0.category.caseInsensitiveCompare(category) == .orderedSame }?.actions ?? []
    }
}
