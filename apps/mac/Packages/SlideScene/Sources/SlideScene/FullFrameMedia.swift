import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

extension SlideSceneBuilder {

    /// Full-screen media fits inside the canvas by default, with black filling
    /// the rest, so an image that isn't the screen's shape is never cropped.
    /// A media item set to Fill (or Stretch) keeps that instead.
    public static func fullFrameMediaItems(
        id: String, mediaId: String, scaleMode: MediaScaleMode?, canvasSize: CGSize
    ) -> [RenderItem] {
        let frame = CGRect(origin: .zero, size: canvasSize)
        let mode: SceneMediaScaleMode = switch scaleMode {
        case .none, .fit: .fit
        case .fill: .fill
        case .stretch: .stretch
        }
        let media = RenderItem(id: id, frame: frame, content: .media(id: mediaId, scaleMode: mode))
        guard mode == .fit else { return [media] }
        let backing = RenderItem(
            id: "\(id)-letterbox", frame: frame,
            content: .solid(SceneColor(red: 0, green: 0, blue: 0)))
        return [backing, media]
    }
}

extension RenderScene {
    mutating func addItems(_ items: [RenderItem], to kind: LayerKind) {
        for item in items { addItem(item, to: kind) }
    }
}
