import AVFoundation
import CoreMedia
import VideoToolbox

/// Something a playing video ran into that the app should hear about.
/// Before these were reported a video that couldn't play sat in the
/// player table looking like it was about to start: the screens waited on
/// it and the plan never moved on.
public enum PlaybackProblem: Sendable, Equatable {
    /// The item, the player or the looper failed, or the item couldn't
    /// play to its end. The player is finished; the engine has already
    /// taken it off its id.
    case failed(String)
    /// The player ran out of decoded frames and is waiting for more. It
    /// may recover on its own, so this is only worth logging.
    case stalled
}

extension MediaEngine {
    /// One line for the diagnostics log: the message, and the error's
    /// domain and code with the underlying one's, which is where
    /// AVFoundation puts the decoder's own status.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? MediaEngineError {
            return error.localizedDescription
        }
        let ns = error as NSError
        var line = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        if let reason = ns.localizedFailureReason { line += " \(reason)" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            line += " ← \(underlying.domain) \(underlying.code)"
        }
        return line
    }

    /// "hvc1", "avc1", "apcn": the codec as files and tools name it.
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}

extension PreparedMedia {
    /// What the diagnostics log needs to tell one video from another when
    /// it won't play: size, codec, frame rate and whether this Mac decodes
    /// that codec in hardware.
    public var summary: String {
        let fps = frameDuration > 0 ? (1 / frameDuration).formatted(.number.precision(.fractionLength(0 ... 2))) : "?"
        let decode = hardwareDecodes ? "hardware decode" : "software decode"
        return "\(Int(naturalSize.width))×\(Int(naturalSize.height)) \(codec) \(fps) fps, "
            + "\(Int(duration.rounded())) s, \(decode)"
    }

    static func hardwareDecodes(_ subtype: FourCharCode) -> Bool {
        VTIsHardwareDecodeSupported(CMVideoCodecType(subtype))
    }
}
