import PresenterCore
import SwiftUI

/// The three ways to add a slide from a "+": a design from a theme, a
/// picture or video from the Media library, or a blank slide. The Present
/// page's empty presentations, its last-tile "+", and the editor's empty
/// canvas all offer the same three.
struct AddSlideChoices {
    let fromTheme: () -> Void
    let fromMedia: () -> Void
    let blank: () -> Void
}

struct AddSlideMenuItems: View {
    let choices: AddSlideChoices

    var body: some View {
        Button("Slide from Theme\u{2026}", systemImage: "paintpalette", action: choices.fromTheme)
        Button("From Media Library\u{2026}", systemImage: "photo.on.rectangle", action: choices.fromMedia)
        Button("Blank Slide", systemImage: "rectangle", action: choices.blank)
    }
}

/// Where a presentation's slides would be when it has none: a slide-sized
/// dashed space that takes slides dragged from another presentation, Media
/// library items and files from the Finder, with a "+" for the three ways to
/// add one. Locked, it only says there are no slides.
struct EmptySlidesDropArea: View {
    let aspect: CGFloat
    let locked: Bool
    let choices: AddSlideChoices
    /// A dragged slide's payload or a library item's id; false turns the
    /// drop down.
    let dropText: (String) -> Bool
    let dropFiles: ([URL]) -> Void

    var breadcrumb = "grid.emptyDrop"
    /// Payloads this place never takes (the editor's own object and slide
    /// drags).
    var rejectPrefixes: [String]? = nil
    var roundedCorners = true

    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle.standard(roundedCorners ? CornerStandard.element : 0)
        shape
            .fill(Color.primary.opacity(targeted ? 0.08 : 0.03))
            .overlay {
                shape.strokeBorder(
                    targeted ? Color.accentColor : Color.primary.opacity(0.22),
                    style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4]))
            }
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { content }
            .contentShape(shape)
            .onDrop(of: [.plainText, .fileURL], delegate: GutterDropDelegate(
                enabled: !locked,
                breadcrumb: breadcrumb,
                dropStarted: { targeted = false },
                setLine: { targeted = $0 },
                setRing: { _ in },
                performText: { payload, _ in !locked && dropText(payload) },
                performFiles: { urls, _ in if !locked { dropFiles(urls) } },
                insertOnly: true,
                rejectPrefixes: rejectPrefixes
            ))
    }

    @ViewBuilder
    private var content: some View {
        if locked {
            Text("No slides")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                Menu {
                    AddSlideMenuItems(choices: choices)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.accentColor))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a slide")
                Text("Drop slides or media here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
        }
    }
}

/// Picks pictures and videos to become slides, each with its media as the
/// background: the Media Library's browser (its categories and search) in
/// picking mode.
struct MediaSlidePickerSheet: View {
    let model: AppModel
    /// The picked media ids, in the order they were picked.
    let onPick: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MediaLibraryView(model: model, picking: MediaLibraryPicking(
            add: { ids in
                guard !ids.isEmpty else { return }
                onPick(ids)
                dismiss()
            },
            cancel: { dismiss() }))
    }
}

/// A sheet request for the media picker: where the new slides land.
struct MediaSlideTarget: Identifiable {
    let id = UUID()
    let presentationID: String
    /// The slide they follow; nil for an empty presentation.
    let afterSlideID: String?
    /// The arranged position they go before, for the slide grid.
    var beforeIndex: Int = 0
}

enum MediaSlides {
    /// New slides, one per picture or video, with it as the background, the
    /// same as dropping media between slides.
    @MainActor
    static func make(_ mediaIDs: [String], model: AppModel, sectionId: String? = nil) -> [Slide] {
        mediaIDs.compactMap { model.media($0) }.map { item in
            Slide(
                id: UUID().uuidString,
                name: item.name,
                objects: [],
                background: CueMedia.droppedAsNewSlide(for: item),
                sectionId: sectionId)
        }
    }
}
