import CoreGraphics
import Foundation
import RenderEngine

public enum SignageSceneBuilder {
    public static func scene(mediaID: String, canvasSize: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        scene.addItems(
            SlideSceneBuilder.fullFrameMediaItems(
                id: "signage-\(mediaID)", mediaId: mediaID, scaleMode: nil, canvasSize: canvasSize),
            to: .videos
        )
        return scene
    }
}
