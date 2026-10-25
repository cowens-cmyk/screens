import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// Picks a picture for a slide's lower third on the livestream and brings
/// it into the media library like any other import, so it syncs with the
/// deck and shows in Media.
@MainActor
enum LowerThirdImagePicker {
    static func choose(_ model: AppModel, then use: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .image]
        panel.message = "A PNG with transparency, 1920 × 1080 or a strip for the bottom."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let id = await importImage(url, into: model) { use(id) }
            }
        }
    }

    /// Only a picture can go over the camera; a video file is turned away.
    static func importImage(_ url: URL, into model: AppModel) async -> String? {
        guard let id = await model.importFiles([url]).first,
              model.media(id)?.mediaKind == .image
        else { return nil }
        return id
    }
}

/// "Don't ask again for this presentation", kept on this Mac rather than in
/// the presentation: it's how this operator likes to work, not part of the
/// deck, and keeping it out of the document means no sync traffic or merge
/// for a preference about a question.
enum LivestreamPromptMemory {
    private static let key = "livestreamPrompt.skippedPresentations"

    static func isSkipped(_ presentationID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(presentationID)
    }

    static func skip(_ presentationID: String) {
        var skipped = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !skipped.contains(presentationID) else { return }
        skipped.append(presentationID)
        UserDefaults.standard.set(skipped, forKey: key)
    }
}

/// New picture or video slides waiting for their livestream choice.
struct LivestreamPromptRequest: Identifiable {
    var id = UUID()
    let presentationID: String
    let slides: [(id: String, name: String)]
    /// Writes the choice to these slides, through whichever model added them.
    let apply: @MainActor (StreamDesign?, [String]) -> Void

    /// Nil when none of the added slides needs asking about.
    @MainActor
    static func make(
        _ model: AppModel, presentationID: String, added: [Slide],
        apply: @escaping @MainActor (StreamDesign?, [String]) -> Void
    ) -> LivestreamPromptRequest? {
        let ids = LivestreamPrompt.slidesToAsk(
            added: added, skipped: LivestreamPromptMemory.isSkipped(presentationID)
        ) { model.media($0)?.mediaKind }
        guard !ids.isEmpty else { return nil }
        let names = Dictionary(added.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return LivestreamPromptRequest(
            presentationID: presentationID, slides: ids.map { ($0, names[$0] ?? "") }, apply: apply)
    }

    /// A second drop while the question is up joins it, keeping its id so
    /// the open sheet carries on instead of closing and opening again.
    func adding(_ other: LivestreamPromptRequest?) -> LivestreamPromptRequest {
        guard let other, other.presentationID == presentationID else { return self }
        let known = Set(slides.map(\.id))
        return LivestreamPromptRequest(
            id: id, presentationID: presentationID,
            slides: slides + other.slides.filter { !known.contains($0.id) }, apply: apply)
    }
}

/// "What do you want on the livestream?" for slides just made from pictures
/// or videos. Each answer is the same choice as the slide's right-click ›
/// Livestream, so it can be changed there later.
struct LivestreamPromptSheet: View {
    let model: AppModel
    let request: LivestreamPromptRequest

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var applyToAll = true
    @State private var dontAskAgain = false
    @State private var dropTargeted = false

    private var remaining: Int { request.slides.count - index }

    private var current: (id: String, name: String)? {
        request.slides.indices.contains(index) ? request.slides[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want on the livestream?").font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(spacing: 8) {
                choice(
                    "Lower-Third Image…", detail: "A PNG over the camera. Choose one, or drop it here.",
                    systemImage: "rectangle.bottomthird.inset.filled"
                ) {
                    LowerThirdImagePicker.choose(model) { answer(.lowerThirdImage(mediaID: $0)) }
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                    }
                }
                .onDrop(of: [.fileURL, .plainText], isTargeted: $dropTargeted, perform: dropImage)
                choice(StreamWording.fullScreen, detail: "The stream shows this slide edge to edge.",
                       systemImage: "rectangle.inset.filled") { answer(.fullScreen) }
                choice(StreamWording.nothing, detail: "Nothing goes over the camera.",
                       systemImage: "video") { answer(.nothing) }
                choice(StreamWording.themeDefault, detail: "The theme and the Livestream switch decide.",
                       systemImage: "paintpalette") { answer(.themeDefault) }
            }
            VStack(alignment: .leading, spacing: 6) {
                if remaining > 1 {
                    Toggle("Apply to all \(remaining) new slides", isOn: $applyToAll)
                }
                Toggle("Don't ask again for this presentation", isOn: $dontAskAgain)
            }
            HStack {
                Spacer()
                Button("Not Now", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var subtitle: String {
        let name = current.map(\.name).flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "This slide"
        if request.slides.count == 1 { return "\(name) is new." }
        return "\(name) — \(index + 1) of \(request.slides.count) new slides."
    }

    private func choice(
        _ title: String, detail: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A PNG from Finder, or a picture dragged from Media.
    private func dropImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let id = await LowerThirdImagePicker.importImage(url, into: model) {
                        answer(.lowerThirdImage(mediaID: id))
                    }
                }
            }
            return true
        }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let id = text as? String else { return }
            Task { @MainActor in
                if model.media(id)?.mediaKind == .image { answer(.lowerThirdImage(mediaID: id)) }
            }
        }
        return true
    }

    private func answer(_ choice: LivestreamPrompt.Choice) {
        guard current != nil else { return }
        if dontAskAgain { LivestreamPromptMemory.skip(request.presentationID) }
        let ids = applyToAll || dontAskAgain
            ? request.slides[index...].map(\.id) : [request.slides[index].id]
        if let design = LivestreamPrompt.design(for: choice) {
            request.apply(design, ids)
        }
        index += ids.count
        if index >= request.slides.count { dismiss() }
    }
}
