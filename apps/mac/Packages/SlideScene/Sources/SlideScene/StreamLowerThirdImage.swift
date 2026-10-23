import CoreGraphics
import RenderEngine

/// A slide's lower-third picture on the livestream: what goes over the
/// camera in place of the slide while that slide is live. The room keeps
/// the slide; only the stream's copy of the slide layer is swapped.
public enum StreamLowerThirdImage {

    /// Where the picture sits. A picture shaped like the canvas fills it
    /// (a full-frame PNG already has its lower third drawn where it goes);
    /// any other shape keeps its proportions at the bottom, full width when
    /// it's wider than the canvas, otherwise as tall as the canvas allows.
    public static func frame(imageSize: CGSize?, canvas: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: canvas)
        guard let imageSize, imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0
        else { return full }
        let aspect = imageSize.width / imageSize.height
        let canvasAspect = canvas.width / canvas.height
        // Within a pixel or two of the canvas shape counts as full frame.
        if abs(aspect - canvasAspect) / canvasAspect < 0.01 { return full }
        var size = CGSize(width: canvas.width, height: canvas.width / aspect)
        if size.height > canvas.height {
            size = CGSize(width: canvas.height * aspect, height: canvas.height)
        }
        return CGRect(
            x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
            width: size.width, height: size.height)
    }

    /// The live scene with its slide layer replaced by the picture. Every
    /// other layer is left as it is; the livestream's routing decides which
    /// of them it carries.
    public static func scene(
        replacingSlideOf scene: RenderScene, mediaID: String, imageSize: CGSize?
    ) -> RenderScene {
        var out = scene
        guard let index = out.layers.firstIndex(where: { $0.kind == .slide }) else { return out }
        out.layers[index].items = [RenderItem(
            id: "stream-lower-third-\(mediaID)",
            frame: frame(imageSize: imageSize, canvas: scene.canvasSize),
            content: .media(id: mediaID, scaleMode: .stretch))]
        return out
    }
}
