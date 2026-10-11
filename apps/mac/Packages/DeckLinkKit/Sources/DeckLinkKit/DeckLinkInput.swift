import Accelerate
import CDeckLink
import CoreVideo
import Foundation
import IOSurface

public struct DeckLinkInputDevice: Sendable, Equatable, Codable {
    public let name: String
    public let persistentID: Int64
    public let supportsCapture: Bool
    public let supportsFormatDetection: Bool

    public let inactive: Bool

    public let inputModeCount: Int
    public let captureBusy: Bool
    public let playbackBusy: Bool

    public init(
        name: String, persistentID: Int64, supportsCapture: Bool,
        supportsFormatDetection: Bool, inactive: Bool, inputModeCount: Int,
        captureBusy: Bool, playbackBusy: Bool
    ) {
        self.name = name
        self.persistentID = persistentID
        self.supportsCapture = supportsCapture
        self.supportsFormatDetection = supportsFormatDetection
        self.inactive = inactive
        self.inputModeCount = inputModeCount
        self.captureBusy = captureBusy
        self.playbackBusy = playbackBusy
    }

    /// Capture hardware, switched on, and its connector mapped as an input in Desktop Video Setup.
    public var isUsableForCapture: Bool {
        supportsCapture && !inactive && inputModeCount > 0
    }
}

public struct DeckLinkInputFormat: Sendable, Equatable, Codable {
    public let width: Int
    public let height: Int
    public let frameDuration: Int64
    public let timeScale: Int64

    /// BMDFieldDominance fourcc ('prog', 'psf ', 'lowr', 'uppr'; 0 unknown).
    public let fieldDominance: UInt32

    /// BMDPixelFormat fourcc the card captures in ('2vuy' or 'BGRA').
    public let pixelFormat: UInt32

    public init(
        width: Int, height: Int, frameDuration: Int64, timeScale: Int64,
        fieldDominance: UInt32, pixelFormat: UInt32
    ) {
        self.width = width
        self.height = height
        self.frameDuration = frameDuration
        self.timeScale = timeScale
        self.fieldDominance = fieldDominance
        self.pixelFormat = pixelFormat
    }

    static let progressive: UInt32 = 0x7072_6F67
    static let segmented: UInt32 = 0x7073_6620
    static let lowerFirst: UInt32 = 0x6C6F_7772
    static let upperFirst: UInt32 = 0x7570_7072

    public var framesPerSecond: Double {
        frameDuration == 0 ? 0 : Double(timeScale) / Double(frameDuration)
    }

    public var isInterlaced: Bool {
        fieldDominance == Self.lowerFirst || fieldDominance == Self.upperFirst
    }

    /// Broadcast-style name: "1080p59.94", "1080i59.94" (field rate), "1080PsF23.98", "2160p50".
    public var label: String {
        let scan: String
        var rate = framesPerSecond
        switch fieldDominance {
        case Self.lowerFirst, Self.upperFirst:
            scan = "i"
            rate *= 2
        case Self.segmented:
            scan = "PsF"
        default:
            scan = "p"
        }
        var number = String(format: "%.2f", rate)
        while number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return "\(height)\(scan)\(number)"
    }
}

extension DeckLinkRuntime {
    public static func inputDevices() -> [DeckLinkInputDevice] {
        let capacity = 32
        var raw = [DLKInputDeviceInfo](repeating: DLKInputDeviceInfo(), count: capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            dlk_copy_input_devices(buffer.baseAddress, Int32(capacity))
        }
        return raw.prefix(Int(count)).map { info in
            DeckLinkInputDevice(
                name: withUnsafeBytes(of: info.name) { bytes in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                },
                persistentID: info.persistentID,
                supportsCapture: info.supportsCapture,
                supportsFormatDetection: info.supportsFormatDetection,
                inactive: info.inactive,
                inputModeCount: Int(info.inputModeCount),
                captureBusy: info.captureBusy,
                playbackBusy: info.playbackBusy)
        }
    }
}

/// Captures one DeckLink input port and keeps its latest picture as an IOSurface-backed BGRA
/// `CVPixelBuffer`. The card captures 8-bit 4:2:2 (or BGRA for RGB 4:4:4 sources when it can);
/// 4:2:2 is converted to BGRA with vImage on the driver's callback thread.
public final class DeckLinkInputSource: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case noSignal
        case receiving(DeckLinkInputFormat)
        case failed(String)
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let receiver: Receiver

    /// - Parameter onFrame: called on the driver's thread with each converted frame.
    public init(
        persistentID: Int64, onFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil
    ) throws {
        receiver = Receiver(onFrame: onFrame)
        var error = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(receiver).toOpaque()
        guard let opened = dlk_input_open(
            persistentID, deckLinkInputFrameArrived, context, &error, error.count)
        else {
            throw DeckLinkError.openFailed(String(cString: error))
        }
        handle = opened
    }

    public func latestFrame() -> CVPixelBuffer? {
        receiver.latest()
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return .failed("stopped") }
        var status = DLKInputStatus()
        dlk_input_copy_status(handle, &status)
        switch status.signal {
        case DLKInputSignalFailed:
            let message = withUnsafeBytes(of: status.error) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            return .failed(message.isEmpty ? "capture failed" : message)
        case DLKInputSignalLocked where receiver.secondsSinceLastFrame < 1:
            return .receiving(DeckLinkInputFormat(
                width: Int(status.width), height: Int(status.height),
                frameDuration: status.frameDuration, timeScale: status.timeScale,
                fieldDominance: status.fieldDominance, pixelFormat: status.pixelFormat))
        default:
            return .noSignal
        }
    }

    public func stop() {
        lock.lock()
        let closing = handle
        handle = nil
        lock.unlock()
        if let closing { dlk_input_close(closing) }
        receiver.clear()
    }

    deinit {
        if let handle { dlk_input_close(handle) }
    }

    final class Receiver: @unchecked Sendable {
        private let onFrame: (@Sendable (CVPixelBuffer) -> Void)?
        private let lock = NSLock()
        private var latestBuffer: CVPixelBuffer?
        private var lastFrameAt: TimeInterval = 0

        // Touched only on the driver's callback thread.
        private var ring: [CVPixelBuffer] = []
        private var ringKey = (width: 0, height: 0)
        private var conversion: vImage_YpCbCrToARGB?
        private var conversionColorspace: UInt32 = 0

        static let maxRing = 12

        init(onFrame: (@Sendable (CVPixelBuffer) -> Void)?) {
            self.onFrame = onFrame
        }

        func latest() -> CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return latestBuffer
        }

        var secondsSinceLastFrame: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return ProcessInfo.processInfo.systemUptime - lastFrameAt
        }

        func clear() {
            lock.lock()
            latestBuffer = nil
            lock.unlock()
        }

        func receive(_ frame: DLKInputFrame) {
            guard let bytes = frame.bytes, frame.width > 0, frame.height > 0,
                let buffer = nextBuffer(width: Int(frame.width), height: Int(frame.height))
            else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            let converted = CVPixelBufferGetBaseAddress(buffer).map { base in
                write(frame, from: bytes, into: base, rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            } ?? false
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard converted else { return }
            lock.lock()
            latestBuffer = buffer
            lastFrameAt = ProcessInfo.processInfo.systemUptime
            lock.unlock()
            onFrame?(buffer)
        }

        /// A ring buffer that nobody holds: not the latest frame, and its IOSurface's global use
        /// count is zero (the app and in-flight XPC sends raise it while they hold the surface).
        private func nextBuffer(width: Int, height: Int) -> CVPixelBuffer? {
            if ringKey != (width, height) {
                ring = []
                ringKey = (width, height)
            }
            let current = latest()
            for buffer in ring where buffer !== current {
                guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
                else { continue }
                if !IOSurfaceIsInUse(surface) { return buffer }
            }
            guard ring.count < Self.maxRing else { return nil }
            var created: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &created) == kCVReturnSuccess,
                let created
            else { return nil }
            ring.append(created)
            return created
        }

        private func write(
            _ frame: DLKInputFrame, from bytes: UnsafePointer<UInt8>,
            into base: UnsafeMutableRawPointer, rowBytes: Int
        ) -> Bool {
            let width = Int(frame.width)
            let height = Int(frame.height)
            switch frame.pixelFormat {
            case 0x4247_5241:  // 'BGRA'
                for row in 0..<height {
                    memcpy(
                        base.advanced(by: row * rowBytes),
                        bytes.advanced(by: row * frame.rowBytes),
                        min(rowBytes, frame.rowBytes, width * 4))
                }
                return true
            case 0x3276_7579:  // '2vuy'
                guard var info = conversion(for: frame.colorspace) else { return false }
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: bytes),
                    height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: frame.rowBytes)
                var destination = vImage_Buffer(
                    data: base, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: rowBytes)
                // ARGB → BGRA.
                let permute: [UInt8] = [3, 2, 1, 0]
                return vImageConvert_422CbYpCrYp8ToARGB8888(
                    &source, &destination, &info, permute, 255,
                    vImage_Flags(kvImageNoFlags)) == kvImageNoError
            default:
                return false
            }
        }

        private func conversion(for colorspace: UInt32) -> vImage_YpCbCrToARGB? {
            if let conversion, conversionColorspace == colorspace { return conversion }
            var range = vImage_YpCbCrPixelRange(
                Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            // Coefficients written out: vImage's matrix globals are mutable C vars Swift 6 rejects.
            var matrix: vImage_YpCbCrToARGBMatrix
            switch colorspace {
            case 0x7236_3031:  // 'r601'
                matrix = vImage_YpCbCrToARGBMatrix(
                    Yp: 1, Cr_R: 1.402, Cr_G: -0.714_136, Cb_G: -0.344_136, Cb_B: 1.772)
            case 0x3230_3230:  // '2020'
                matrix = vImage_YpCbCrToARGBMatrix(
                    Yp: 1, Cr_R: 1.4746, Cr_G: -0.571_35, Cb_G: -0.164_55, Cb_B: 1.8814)
            default:  // 'r709'
                matrix = vImage_YpCbCrToARGBMatrix(
                    Yp: 1, Cr_R: 1.5748, Cr_G: -0.468_124, Cb_G: -0.187_324, Cb_B: 1.8556)
            }
            var info = vImage_YpCbCrToARGB()
            let status = vImageConvert_YpCbCrToARGB_GenerateConversion(
                &matrix, &range, &info,
                kvImage422CbYpCrYp8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
            guard status == kvImageNoError else { return nil }
            conversion = info
            conversionColorspace = colorspace
            return info
        }
    }
}

private func deckLinkInputFrameArrived(
    context: UnsafeMutableRawPointer?, frame: UnsafePointer<DLKInputFrame>?
) {
    guard let context, let frame else { return }
    Unmanaged<DeckLinkInputSource.Receiver>.fromOpaque(context)
        .takeUnretainedValue().receive(frame.pointee)
}
