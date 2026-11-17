import Foundation

/// How Hope's songs look, carried in every exported presentation and plan
/// so another Mac running Screens shows them the same way: the stage
/// display layouts, the lyrics theme new songs use, and the Worship type's
/// settings (its livestream look, and the actions a song runs going up,
/// such as its worship background). These are church-wide settings, not
/// part of any one presentation, so they travel beside it in look.json.
///
/// On import the stage displays replace the other Mac's (they're the same
/// fixed ids on every library), and the Worship settings fill in only what
/// that Mac hasn't set, so its own choices stay.
public struct ShareLook: Codable, Equatable, Sendable {
    public static let fileName = "look.json"

    /// The stage display layouts every library has, by fixed id.
    public static let stageLayoutIDs = [
        BasicTemplates.worshipStageID, BasicTemplates.messageStageID, BasicTemplates.videoStageID,
        BasicTemplates.preServiceStageID, BasicTemplates.announcementsStageID,
    ]

    public var lyricsImportThemeId: String?
    public var worshipScreens: PresentationTypeScreens?
    public var worshipRule: PresentationTypeRule?

    public init(
        lyricsImportThemeId: String? = nil, worshipScreens: PresentationTypeScreens? = nil,
        worshipRule: PresentationTypeRule? = nil
    ) {
        self.lyricsImportThemeId = lyricsImportThemeId
        self.worshipScreens = worshipScreens
        self.worshipRule = worshipRule
    }

    /// This library's look, from its settings.
    public init(_ settings: SlideBuildingSettings?) {
        let worship = PresentationTypes.worship
        self.init(
            lyricsImportThemeId: settings?.lyricsImportThemeId,
            worshipScreens: settings?.typeScreens?.first { $0.category.caseInsensitiveCompare(worship) == .orderedSame },
            worshipRule: settings?.presentationTypeRules?.first { $0.category.caseInsensitiveCompare(worship) == .orderedSame })
    }

    public var isEmpty: Bool { lyricsImportThemeId == nil && worshipScreens == nil && worshipRule == nil }

    /// Documents the look names (themes, media, layouts), for the export to
    /// carry: every id-looking string in it, which the export keeps only
    /// when a document has that id.
    public var referencedIDs: [String] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return Self.stageLayoutIDs }
        var strings: [String] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] { dictionary.values.forEach(walk) }
            else if let array = node as? [Any] { array.forEach(walk) }
            else if let string = node as? String, string.count >= 8 { strings.append(string) }
        }
        walk(object)
        return Self.stageLayoutIDs + strings
    }

    /// The other Mac's settings with this look filled in where it has none:
    /// a Worship row or rule only when it has no row or rule for Worship
    /// (merging actions could start two backgrounds), the lyrics theme only
    /// when it's unset or still the one every library starts with. Nil when
    /// nothing changes.
    public func filling(_ settings: SlideBuildingSettings) -> SlideBuildingSettings? {
        var out = settings
        let worship = PresentationTypes.worship
        if let row = worshipScreens,
           !(out.typeScreens ?? []).contains(where: { $0.category.caseInsensitiveCompare(worship) == .orderedSame }) {
            out.typeScreens = (out.typeScreens ?? []) + [row]
        }
        if let rule = worshipRule,
           !(out.presentationTypeRules ?? []).contains(where: { $0.category.caseInsensitiveCompare(worship) == .orderedSame }) {
            out.presentationTypeRules = (out.presentationTypeRules ?? []) + [rule]
        }
        if let theme = lyricsImportThemeId,
           out.lyricsImportThemeId == nil || out.lyricsImportThemeId == BasicTemplates.worshipThemeID {
            out.lyricsImportThemeId = theme
        }
        return out == settings ? nil : out
    }
}
