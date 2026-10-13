import CoreGraphics
import Foundation

/// What a keyed livestream output is putting over the camera right now:
/// nothing (transparent), graphics that leave the camera visible (a lower
/// third, lyrics, a logo), or something that covers the whole frame (a
/// full slide, a video, a background).
public enum StreamCoverage: String, Sendable, Equatable {
    case transparent
    case lowerThird
    case fullScreen

    /// A filled item covering this much of the frame counts as full screen.
    static let fullScreenShare = 0.85

    public static func classify(_ scene: RenderScene) -> StreamCoverage {
        let canvas = CGRect(origin: .zero, size: scene.canvasSize)
        let canvasArea = max(canvas.width * canvas.height, 1)
        var anything = false
        for layer in scene.layers where !layer.isHidden {
            for item in layer.items where item.opacity > 0.01 {
                let visible = item.frame.intersection(canvas)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
                switch item.content {
                case .text(let text):
                    if !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { anything = true }
                case .solid(let color):
                    guard color.alpha > 0.01 else { continue }
                    anything = true
                    if visible.width * visible.height / canvasArea >= fullScreenShare { return .fullScreen }
                case .shape, .media:
                    anything = true
                    if visible.width * visible.height / canvasArea >= fullScreenShare { return .fullScreen }
                }
            }
        }
        return anything ? .lowerThird : .transparent
    }
}
