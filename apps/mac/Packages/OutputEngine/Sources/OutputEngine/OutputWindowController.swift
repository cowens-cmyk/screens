import AppKit
import RenderEngine

@MainActor
public final class OutputWindowController {
    public let displayUUID: DisplayUUID
    public let sceneView: MetalSceneView
    private let window: OutputWindow

    public var frame: CGRect { window.frame }

    public init(
        display: DisplaySnapshot,
        screen: NSScreen,
        compositor: Compositor,
        sceneProvider: @escaping @Sendable () -> RenderScene
    ) {
        displayUUID = display.uuid
        sceneView = MetalSceneView(compositor: compositor)
        sceneView.sceneProvider = sceneProvider
        sceneView.activity.kind = "output"
        sceneView.activity.label = "Output window on \(display.name)"

        window = OutputWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Output — \(display.name)"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [
            .fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle,
        ]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = sceneView
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    public func reframe(to frame: CGRect) {
        window.setFrame(frame, display: true)
    }

    public func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

// The audience sees this window, so it never takes the keyboard: a stray
// click on the projector would otherwise leave the slide keys going nowhere.
// Nothing done on it turns the screen off either; that is Settings › Screens.
private final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
