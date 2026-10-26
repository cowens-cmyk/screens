import Foundation

/// How a screen's frames carry transparency to whatever receives them.
///
/// The livestream is laid over the camera, so its frames have to say where
/// they are see-through. A frame drawn on black with alpha 255 everywhere
/// leaves the receiver only a luma key, which drops everything dark: a
/// black lower-third bar vanishes and colored bars go part see-through.
public struct OutputKeying: Sendable, Equatable {
    /// Clear where nothing is drawn, instead of the scene's background.
    public var transparentBackground: Bool
    /// Colors at full strength rather than multiplied by alpha.
    public var straightAlpha: Bool

    public init(transparentBackground: Bool, straightAlpha: Bool) {
        self.transparentBackground = transparentBackground
        self.straightAlpha = straightAlpha
    }

    /// The whole picture, as a projector shows it.
    public static let fullPicture = OutputKeying(transparentBackground: false, straightAlpha: false)

    /// An NDI sender's frames. NDI's BGRA is straight alpha, and receivers
    /// (OBS, vMix, a switcher) lay it over the camera as they get it, so the
    /// livestream goes with its transparency. The other screens stay whole
    /// pictures: an audience slide's theme color is its background.
    public static func ndi(livestream: Bool) -> OutputKeying {
        livestream ? OutputKeying(transparentBackground: true, straightAlpha: true) : .fullPicture
    }
}
