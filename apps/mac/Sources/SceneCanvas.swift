import RenderEngine
import SwiftUI

struct SceneCanvas: NSViewRepresentable {
    let render: RenderContext

    var transparentBackground = false

    var inset: CGFloat = 0

    /// An editor canvas's zoom and pan; without one the scene is letterboxed
    /// inside `inset`.
    var navigator: CanvasNavigator? = nil

    func makeNSView(context: Context) -> MetalSceneView {
        let view = MetalSceneView(
            compositor: render.compositor, transparentBackground: transparentBackground
        )
        view.sceneProvider = { [sceneBox = render.sceneBox] in
            sceneBox.value
        }
        view.sceneInset = inset
        navigator?.attach(view)
        render.canvasView = view
        return view
    }

    func updateNSView(_ nsView: MetalSceneView, context: Context) {
        nsView.sceneInset = inset
    }
}
