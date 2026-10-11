import Foundation
import IOSurface

@objc protocol DeckLinkHelperProtocol {

    func listDevices(reply: @escaping (Data) -> Void)

    func runtimeVersion(reply: @escaping (String, Bool) -> Void)

    func listDisplayModes(devicePersistentID: Int64, reply: @escaping (Data) -> Void)

    func startOutput(
        devicePersistentID: Int64,
        width: Int32,
        height: Int32,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        keying: Int32,
        modeID: Int64,
        reply: @escaping (_ error: String?, _ wireDetail: String) -> Void
    )

    func sendFrame(_ surface: IOSurface, reply: @escaping (_ delivered: Bool) -> Void)

    func stopOutput()

    func ping(reply: @escaping (Bool) -> Void)

    // MARK: Capture — one input per connection. Frames come back over the connection's
    // exported `DeckLinkInputClientProtocol` object; status is polled.

    func listInputDevices(reply: @escaping (Data) -> Void)

    func startInput(devicePersistentID: Int64, reply: @escaping (_ error: String?) -> Void)

    /// JSON `DeckLinkHelperInputStatus`.
    func inputStatus(reply: @escaping (Data) -> Void)

    func stopInput()
}

/// Exported by the app on a capture connection; the helper pushes each captured frame.
/// The surface is BGRA; the reply releases the helper's hold on it.
@objc protocol DeckLinkInputClientProtocol {
    func inputFrame(_ surface: IOSurface, reply: @escaping () -> Void)
}

struct DeckLinkHelperInputDevice: Codable, Equatable, Identifiable {
    let name: String
    let persistentID: Int64
    let supportsFormatDetection: Bool
    let usableForCapture: Bool
    let captureBusy: Bool
    let playbackBusy: Bool

    var id: Int64 { persistentID }
}

struct DeckLinkHelperInputStatus: Codable, Equatable {
    enum Signal: String, Codable {
        case starting
        case noSignal
        case receiving
        case failed
    }

    var signal: Signal
    /// Detected format, e.g. "1080p59.94", while receiving.
    var format: String?
    var width: Int?
    var height: Int?
    var error: String?
}

struct DeckLinkHelperDevice: Codable, Equatable, Identifiable {
    let name: String
    let persistentID: Int64
    let supportsPlayback: Bool
    let supportsInternalKeying: Bool
    let supportsExternalKeying: Bool

    var id: Int64 { persistentID }
}

struct DeckLinkHelperDisplayMode: Codable, Equatable, Identifiable {
    let name: String

    let modeID: Int64
    let width: Int
    let height: Int

    let frameDuration: Int64
    let timeScale: Int64
    let progressive: Bool

    let supportsKeying: Bool

    var id: Int64 { modeID }

    var framesPerSecond: Double {
        Double(timeScale) / Double(frameDuration)
    }

    var mirrorFramesPerSecond: Int {
        Int((framesPerSecond).rounded())
    }
}

enum DeckLinkHelperIdentity {

    static let serviceName = "com.example.mxuslides.DeckLinkHelper"
}
