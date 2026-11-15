import CoreGraphics

/// Full-screen pictures and videos made to look right whatever their shape.
///
/// A slide's background fits inside the screen so nothing is cropped, with
/// black filling the rest. That left two things that looked wrong: a picture
/// nearly the screen's shape (1918 × 1080, 1440 × 812) showed a thin black
/// line along an edge, and a portrait photo or a 4:3 picture sat in wide
/// black bars. A picture within a few percent of the screen's shape now
/// fills it, and anything else sits over a blurred, dimmed copy of itself
/// that fills the screen, as phones show a photo that isn't their shape.
public enum MediaFraming {
    /// How far a picture's shape may be from the screen's and still fill it:
    /// at most this share of it is cut off.
    public static let nearShare = 0.03
    /// The blur behind an odd-shaped picture, as a share of the screen's height.
    public static let blurShare = 0.04
    /// How bright the blurred copy is drawn over the black, so the picture
    /// itself stands out from it.
    public static let blurOpacity = 0.55

    /// Whether `frame` is the whole canvas, give or take a line of pixels.
    static func coversCanvas(_ frame: CGRect, canvas: CGSize) -> Bool {
        let slack = max(canvas.width, canvas.height) * 0.005
        return abs(frame.minX) <= slack && abs(frame.minY) <= slack
            && abs(frame.maxX - canvas.width) <= slack && abs(frame.maxY - canvas.height) <= slack
    }

    static func isNear(_ size: CGSize, _ canvas: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, canvas.width > 0, canvas.height > 0 else { return false }
        let ratio = (size.width / size.height) / (canvas.width / canvas.height)
        return max(ratio, 1 / ratio) <= 1 + nearShare
    }
}

extension RenderScene {

    /// The scene with each full-screen picture or video set to fit framed
    /// as `MediaFraming` describes. `size` gives a picture's pixel size, nil
    /// when it isn't known yet (the picture is then left as it was).
    public func framingMedia(_ size: (String) -> CGSize?) -> RenderScene {
        var scene = self
        let canvas = canvasSize
        for layerIndex in scene.layers.indices {
            var items: [RenderItem] = []
            for item in scene.layers[layerIndex].items {
                guard case .media(let id, .fit, let sourceRect) = item.content, sourceRect == nil,
                      item.animationSteps.isEmpty,
                      MediaFraming.coversCanvas(item.frame, canvas: canvas),
                      let pixels = size(id), pixels.width > 0, pixels.height > 0
                else { items.append(item); continue }
                var framed = item
                framed.frame = CGRect(origin: .zero, size: canvas)
                if MediaFraming.isNear(pixels, canvas) {
                    framed.content = .media(id: id, scaleMode: .fill, sourceRect: nil)
                } else {
                    var behind = framed
                    behind.id = "\(item.id)-blurfill"
                    behind.content = .media(id: id, scaleMode: .fill, sourceRect: nil)
                    behind.effects = [.blur(radius: canvas.height * MediaFraming.blurShare)] + item.effects
                    behind.opacity = item.opacity * MediaFraming.blurOpacity
                    items.append(behind)
                }
                items.append(framed)
            }
            scene.layers[layerIndex].items = items
        }
        return scene
    }
}
