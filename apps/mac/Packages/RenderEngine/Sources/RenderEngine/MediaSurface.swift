import Metal
import QuartzCore
import simd

public struct VideoColorTransform: Sendable {

    public var ycbcrMatrix: simd_float3x3

    public var ycbcrOffset: SIMD3<Float>

    public var gamutToWorking: simd_float3x3

    public var premultipliedAlpha: Bool

    public init(
        ycbcrMatrix: simd_float3x3,
        ycbcrOffset: SIMD3<Float>,
        gamutToWorking: simd_float3x3,
        premultipliedAlpha: Bool
    ) {
        self.ycbcrMatrix = ycbcrMatrix
        self.ycbcrOffset = ycbcrOffset
        self.gamutToWorking = gamutToWorking
        self.premultipliedAlpha = premultipliedAlpha
    }
}

public enum MediaSurface: @unchecked Sendable {

    case ycbcrBiplanar(luma: MTLTexture, chroma: MTLTexture, transform: VideoColorTransform, retained: [AnyObject])

    case bgra(texture: MTLTexture, transform: VideoColorTransform, retained: [AnyObject])
}

/// Whether a media id's picture can change from one frame to the next
/// without the scene changing: a still holds its picture, while a playing
/// video, a camera or a live feed brings a new one on its own.
public enum MediaMotion: Sendable, Equatable {
    case still
    case moving
}

public protocol MediaTextureSource: AnyObject, Sendable {

    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface?

    func liveCadence(for mediaID: String) -> LiveCadence?

    /// Whether `mediaID` shows a still picture or one that moves by itself.
    /// A source that can't tell says `.moving`, so its frames keep coming.
    func motion(for mediaID: String) -> MediaMotion

    /// Bumped whenever what an id shows is replaced (a still loaded, a video
    /// started or stopped), so a view drawing only stills knows to draw again
    /// although its scene did not change.
    var contentGeneration: UInt64 { get }
}

extension MediaTextureSource {
    public func motion(for mediaID: String) -> MediaMotion { .moving }
    public var contentGeneration: UInt64 { 0 }
}
