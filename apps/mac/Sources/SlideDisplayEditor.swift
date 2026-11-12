import PresenterCore
import SwiftUI

/// Which of a slide's displays the editor is on: what the room sees, or
/// what the stage display shows while the slide is up.
enum EditorDisplay: Hashable {
    case audience
    case stage
}

/// The Audience / Stage switch over the slide editor. Edit opens a slide on
/// Audience; Stage opens the stage layout that slide brings up, in the same
/// place, and Audience comes back to the slide. PlanShell owns the choice.
struct SlideDisplays {
    var showing: EditorDisplay
    /// The display picked, with the slide the audience editor is on.
    var choose: (EditorDisplay, _ slideID: String?) -> Void
    /// Set on the Stage side.
    var stage: StageSide?
    /// Songs: their words and chords, card by card.
    var openWords: (() -> Void)?

    struct StageSide {
        var slideName: String
        /// The slide's own choice; "" when it uses the usual one.
        var slideChoice: String
        /// The layout it uses when it has none of its own.
        var usualName: String
        var layoutName: String
        var setLayout: (String) -> Void
        var copyForSlide: () -> Void
    }
}

/// The bar over the editor's toolbar.
struct SlideDisplayBar: View {
    let appModel: AppModel
    let displays: SlideDisplays
    let currentSlideID: () -> String?

    var body: some View {
        HStack(spacing: 10) {
            Picker("Display", selection: Binding(
                get: { displays.showing },
                set: { displays.choose($0, currentSlideID()) }
            )) {
                Text("Audience").tag(EditorDisplay.audience)
                Text("Stage").tag(EditorDisplay.stage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Audience: what the room sees. Stage: what the stage display shows with this slide.")

            if let stage = displays.stage {
                stageControls(stage)
            }
            Spacer(minLength: 8)
            if let openWords = displays.openWords {
                Button("Words & Chords\u{2026}", action: openWords)
                    .help("Edit the song card by card, with the chord line for the stage display")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stageControls(_ stage: SlideDisplays.StageSide) -> some View {
        Text("\u{201C}\(stage.slideName)\u{201D} shows")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        Picker("Stage layout", selection: Binding(get: { stage.slideChoice }, set: stage.setLayout)) {
            Text("Usual (\(stage.usualName))").tag("")
            Divider()
            ForEach(appModel.entries(of: .confidenceLayout), id: \.id) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
        .help("The stage layout that comes up with this slide")
        Button("Copy for This Slide", action: stage.copyForSlide)
            .help("Changes to \(stage.layoutName) show on every slide that uses it. A copy changes this slide only.")
    }
}

extension AppModel {
    static let builtInStageLayouts: Set<String> = [
        StageLayouts.worshipID, StageLayouts.messageID, StageLayouts.videoID, StageLayouts.preServiceID,
        StageLayouts.announcementsID,
    ]

    /// The stage layout a slide brings up, to edit from the slide: its own,
    /// else the presentation's, else the one its type puts the stage on
    /// (Message for the message, Announcements for announcements, Before
    /// Service for the pre-service slideshow and the walkout, otherwise
    /// Worship). With `slideID` nil,
    /// the one the presentation's slides use when they have none.
    func stageLayoutForSlide(_ slideID: String?, in presentationID: String) -> String {
        let deck = presentation(presentationID)
        let slide = slideID.flatMap { id in deck?.slides.first { $0.id == id } }
        for id in [slide?.stageLayoutId, deck?.stageLayoutId] {
            guard let id, !id.isEmpty, id != StageLayouts.audienceID else { continue }
            // A layout since deleted falls through to the usual one.
            if Self.builtInStageLayouts.contains(id) || indexEntry(id) != nil { return id }
        }
        guard let deck else { return StageLayouts.worshipID }
        if PresentationTypes.category(of: deck) == PresentationTypes.sermon { return StageLayouts.messageID }
        if PresentationTypes.category(of: deck) == PresentationTypes.announcements { return StageLayouts.announcementsID }
        let day = slideBuilding.serviceDay
        if ServiceLighting.isPreService(deck, preServiceID: day?.preServicePresentationId)
            || (day?.walkoutPresentationId).map({ !$0.isEmpty && $0 == deck.id }) == true {
            return StageLayouts.preServiceID
        }
        return StageLayouts.worshipID
    }

    func stageLayoutName(_ id: String) -> String {
        indexEntry(id)?.name ?? StageLayouts.name(for: id)
    }

    /// A copy of a stage layout for one slide, so it can change without
    /// changing every slide that uses the original. The copy's id, once
    /// it's in the library.
    func copyStageLayout(_ id: String, named name: String) async -> String? {
        var layout: ConfidenceLayout
        if let current = currentValue(.confidenceLayout, id: id) as? ConfidenceLayout {
            layout = current
        } else if let loaded = try? await client.loadValue(ConfidenceLayout.self, id: id) {
            layout = loaded
        } else if Self.builtInStageLayouts.contains(id) {
            layout = StageLayouts.make(id)
        } else {
            return nil
        }
        layout.id = UUID().uuidString
        layout.name = name
        guard (try? await createInDrive(layout).value) != nil else { return nil }
        return layout.id
    }
}
