import PresenterCore
import SwiftUI

/// The quiet tags on a plan item: what it does to the stage display and the
/// livestream (StageStreamTags).
extension AppModel {
    func stageStreamTags(for item: ServiceItem, in plan: Service) -> StageStreamTags.Tags? {
        StageStreamTags.tags(for: item, in: plan, library: StageStreamTags.Library(
            presentation: { self.presentation($0) }, media: { self.media($0) },
            theme: { self.theme($0) }, settings: slideBuilding))
    }
}

/// "Lyrics + chords · Lyrics lower third" beside an item's name in Present.
struct StageStreamTagLine: View {
    let tags: StageStreamTags.Tags

    var body: some View {
        HStack(spacing: 6) {
            Label(tags.stage, systemImage: "music.mic")
            Label(tags.stream, systemImage: "dot.radiowaves.left.and.right")
        }
        .labelStyle(TightLabelStyle())
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
        .help(tags.help)
    }
}

/// One small mark on the plan list's row; the tags are in its help.
struct StageStreamGlyph: View {
    let tags: StageStreamTags.Tags

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .help(tags.help)
            .accessibilityLabel(tags.help)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}
