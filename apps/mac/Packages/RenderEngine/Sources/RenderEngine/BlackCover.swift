import CoreGraphics

extension RenderScene {
    /// The id of the opaque black item that stands in for everything.
    public static let blackCoverID = "black-cover"

    /// This scene replaced by one opaque black frame, for the Black switch.
    ///
    /// The cover is a drawn item, not just the background colour: the
    /// livestream's output clears to transparent and skips the background so
    /// the camera shows through, and only a drawn item reaches its key as
    /// solid. It also reads as full screen to StreamCoverage, so the ATEM
    /// keyer goes on air for it. Everything underneath is dropped rather than
    /// hidden: nothing is drawn or decoded for a screen that shows black.
    public func blackedOut() -> RenderScene {
        var cover = RenderScene(canvasSize: canvasSize, background: .black)
        cover.addItem(
            RenderItem(
                id: Self.blackCoverID,
                frame: CGRect(origin: .zero, size: canvasSize),
                content: .solid(.black)),
            to: .alerts)
        return cover
    }
}
