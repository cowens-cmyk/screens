import Foundation
import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

/// What every stage screen renders when nothing overrides it, copied into
/// `RenderContext.stageBox` for the render thread.
struct StagePlan: Sendable {
    var source: StageSource
    /// The audience screen's routed scene, for Mirror and for the video
    /// preview. Nil falls back to the main live scene.
    var audience: (@Sendable () -> RenderScene)?
    /// Stage screens a slide's Show on Stage Display put on the audience
    /// screen, over the mode.
    var mirroredScreens: Set<UUID> = []
    /// The Video layout a playing video brings up; nil when the stage is set
    /// to keep its layout through videos.
    var video: StageVideoPlan?

    static let initial = StagePlan(source: .layout(ConfidenceSceneBuilder.builtInLayout), audience: nil)
}

/// The stage layouts the modes use, and the one a playing video brings up.
/// They are library documents with fixed ids so staff can restyle them;
/// until one exists (or loads) its template stands in.
enum StageLayouts {
    static let worshipID = BasicTemplates.worshipStageID
    static let messageID = BasicTemplates.messageStageID
    /// What the stage shows while a video plays.
    static let videoID = BasicTemplates.videoStageID
    /// Not a layout: a slide's stage choice that shows the audience screen
    /// (right-click › Show on Stage Display).
    static let audienceID = "screens.stage.audience"

    /// The layout a mode shows. Mirror has none; its editor entry point opens
    /// the worship layout.
    static func id(for mode: ShowSetup.StageMode) -> String {
        mode == .message ? messageID : worshipID
    }

    static func template(for id: String) -> ConfidenceLayoutTemplate {
        switch id {
        case messageID: .sermon
        case videoID: .video
        default: .worship
        }
    }

    static func name(for id: String) -> String {
        switch id {
        case messageID: "Stage — Message"
        case videoID: "Stage — Video"
        default: "Stage — Worship"
        }
    }

    /// A fresh layout with the fixed id, for creating the document.
    static func make(_ id: String) -> ConfidenceLayout {
        var layout = template(for: id).make(name: name(for: id))
        layout.id = id
        return layout
    }

    /// Built once so the stand-in's object ids stay put between refreshes.
    static let worshipFallback = make(worshipID)
    static let messageFallback = make(messageID)
    static let videoFallback = make(videoID)

    static func fallback(for id: String) -> ConfidenceLayout {
        switch id {
        case messageID: messageFallback
        case videoID: videoFallback
        default: worshipFallback
        }
    }
}

/// The audience, livestream and stage screens: the ones chosen in Settings ›
/// Show Setup, else a guess from the screens' roles and names.
@MainActor
struct ShowTargets {
    var audience: String?
    var stream: String?
    var stage: String?

    init(setup: ShowSetup, render: RenderContext) {
        let screens = PreviewTargets.screens(render)
        func named(_ words: [String]) -> String? {
            screens.first { screen in words.contains { screen.name.lowercased().contains($0) } }?.id
        }
        let outputs = render.outputs
        if screens.contains(where: { $0.id == setup.stageTarget }) {
            stage = setup.stageTarget
        } else if let confidence = outputs.placeholderScreens.first(where: {
            outputs.role(forScreen: $0.id) == .confidence
        }) {
            stage = confidence.id.uuidString
        } else {
            stage = named(["stage", "confidence"])
        }
        if screens.contains(where: { $0.id == setup.streamTarget }) {
            stream = setup.streamTarget
        } else {
            stream = named(["stream", "live", "broadcast", "lower"])
        }
        if screens.contains(where: { $0.id == setup.audienceTarget }) {
            audience = setup.audienceTarget
        } else {
            let taken = Set([stage, stream].compactMap { $0 })
            audience = named(["audience", "main", "front", "projector"])
                ?? screens.first { !taken.contains($0.id) }?.id
        }
    }

    /// The audience screen, unless it is itself a stage screen — mirroring
    /// that would draw the stage into itself.
    static func mirrorSource(setup: ShowSetup, render: RenderContext) -> String? {
        guard let audience = ShowTargets(setup: setup, render: render).audience else { return nil }
        if let id = UUID(uuidString: audience),
           render.outputs.placeholderScreens.contains(where: { $0.id == id }),
           render.outputs.role(forScreen: id) == .confidence {
            return nil
        }
        return audience
    }
}

/// "Video" while a playing video has taken over the stage display.
struct StageVideoBadge: View {
    let render: RenderContext
    @State private var active = false

    var body: some View {
        Group {
            if active {
                Text("Video")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                    .help("A video is playing, so the stage shows it and the time left")
            }
        }
        .task {
            let box = render.confidenceBox
            let plan = render.stageBox
            while !Task.isCancelled {
                let next = plan.value.video != nil
                    && StageScenes.activeVideo(in: box.value, at: Date()) != nil
                if next != active { active = next }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
