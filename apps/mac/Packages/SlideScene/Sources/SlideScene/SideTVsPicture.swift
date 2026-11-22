import CoreGraphics
import PresenterCore
import RenderEngine

/// A slide's own picture for the side TVs: a sermon slide exported three
/// ways ("Slide01_Wide" for the room, "Slide01_LowerThird" for the
/// livestream, "Slide01_SideTVs" for the TVs) shows its TV version there
/// while it's live. The room's picture is set for the wide wall, so on a
/// TV beside it the words come out small; the TV version is laid out for
/// the TV. Slides without one go to the TVs as they always have.
public enum SideTVsPicture {

    /// The live slide's side TVs picture, when it has one still in the
    /// library. A picture that's gone leaves the TVs on the room's slide.
    public static func mediaID(of slide: Slide?, exists: (String) -> Bool) -> String? {
        guard let id = slide?.sideTVsMediaId, !id.isEmpty, exists(id) else { return nil }
        return id
    }

    /// Where the picture sits: as large as the canvas allows, centred, with
    /// its proportions kept. One shaped like the canvas fills it.
    public static func frame(imageSize: CGSize?, canvas: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: canvas)
        guard let imageSize, imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0
        else { return full }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    /// The live scene with its slide layer replaced by the picture over
    /// black, so the room's background (the wide picture, or a video) doesn't
    /// show around or through it. Overlays and alerts are left as they are.
    public static func scene(
        replacingSlideOf scene: RenderScene, mediaID: String, imageSize: CGSize?
    ) -> RenderScene {
        var out = scene
        guard let index = out.layers.firstIndex(where: { $0.kind == .slide }) else { return out }
        let canvas = scene.canvasSize
        out.layers[index].items = [
            RenderItem(
                id: "side-tvs-picture-backing", frame: CGRect(origin: .zero, size: canvas),
                content: .solid(.black)),
            RenderItem(
                id: "side-tvs-picture-\(mediaID)",
                frame: frame(imageSize: imageSize, canvas: canvas),
                content: .media(id: mediaID, scaleMode: .stretch)),
        ]
        return out
    }
}
