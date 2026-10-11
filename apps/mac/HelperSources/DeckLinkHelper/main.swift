import CoreVideo
import DeckLinkKit
import Foundation
import IOSurface

final class DeckLinkOutputStore: @unchecked Sendable {
    static let shared = DeckLinkOutputStore()
    private let lock = NSLock()
    private var outputs: [Int64: (output: DeckLinkOutput, generation: UUID)] = [:]

    func evict(device: Int64) {
        lock.lock()
        let dropped = outputs.removeValue(forKey: device)
        lock.unlock()
        releaseDetached(dropped?.output)
    }

    func install(device: Int64, output: DeckLinkOutput) -> UUID {
        let generation = UUID()
        lock.lock()
        defer { lock.unlock() }
        outputs[device] = (output, generation)
        return generation
    }

    func close(device: Int64, generation: UUID) {
        lock.lock()
        guard outputs[device]?.generation == generation else {
            lock.unlock()
            return
        }
        let dropped = outputs.removeValue(forKey: device)
        lock.unlock()
        releaseDetached(dropped?.output)
    }

    private func releaseDetached(_ output: DeckLinkOutput?) {
        guard let output else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = output  
        }
    }

    func output(device: Int64, generation: UUID) -> DeckLinkOutput? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = outputs[device], entry.generation == generation
        else { return nil }
        return entry.output
    }
}

/// One capture per DeckLink port, shared by every connection that asks for it (two inputs in
/// the app can point at the same port; the card only lets one process-side open capture).
final class DeckLinkInputStore: @unchecked Sendable {
    static let shared = DeckLinkInputStore()
    typealias Subscriber = @Sendable (CVPixelBuffer) -> Void

    private final class Capture {
        var source: DeckLinkInputSource?
        var subscribers: [UUID: Subscriber] = [:]
    }

    private let lock = NSLock()
    private var captures: [Int64: Capture] = [:]

    func subscribe(device: Int64, token: UUID, onFrame: @escaping Subscriber) throws {
        lock.lock()
        if let capture = captures[device] {
            capture.subscribers[token] = onFrame
            lock.unlock()
            return
        }
        let capture = Capture()
        capture.subscribers[token] = onFrame
        captures[device] = capture
        lock.unlock()
        do {
            let source = try DeckLinkInputSource(persistentID: device) { [weak self] buffer in
                self?.fanOut(device: device, buffer: buffer)
            }
            lock.lock()
            if captures[device] === capture {
                capture.source = source
                lock.unlock()
            } else {
                lock.unlock()
                source.stop()
            }
        } catch {
            lock.lock()
            if captures[device] === capture { captures[device] = nil }
            lock.unlock()
            throw error
        }
    }

    func unsubscribe(device: Int64, token: UUID) {
        lock.lock()
        guard let capture = captures[device] else {
            lock.unlock()
            return
        }
        capture.subscribers[token] = nil
        guard capture.subscribers.isEmpty else {
            lock.unlock()
            return
        }
        captures[device] = nil
        let source = capture.source
        lock.unlock()
        // Closing waits out the driver's callback; keep it off the XPC queue.
        DispatchQueue.global(qos: .utility).async { source?.stop() }
    }

    func state(device: Int64) -> DeckLinkInputSource.State? {
        lock.lock()
        let source = captures[device]?.source
        lock.unlock()
        return source?.state
    }

    private func fanOut(device: Int64, buffer: CVPixelBuffer) {
        lock.lock()
        let subscribers = captures[device].map { Array($0.subscribers.values) } ?? []
        lock.unlock()
        for subscriber in subscribers { subscriber(buffer) }
    }
}

final class DeckLinkHelperService: NSObject, DeckLinkHelperProtocol, @unchecked Sendable {

    private var device: Int64?
    private var generation: UUID?

    weak var connection: NSXPCConnection?
    private let inputLock = NSLock()
    private var inputDevice: Int64?
    private let inputToken = UUID()
    private var inputError: String?
    private let framesInFlight = Locked(0)

    func listDevices(reply: @escaping (Data) -> Void) {
        let devices = DeckLinkRuntime.devices().map { device in
            DeckLinkHelperDevice(
                name: device.name,
                persistentID: device.persistentID,
                supportsPlayback: device.supportsPlayback,
                supportsInternalKeying: device.supportsInternalKeying,
                supportsExternalKeying: device.supportsExternalKeying)
        }
        reply((try? JSONEncoder().encode(devices)) ?? Data())
    }

    func runtimeVersion(reply: @escaping (String, Bool) -> Void) {
        reply(
            DeckLinkRuntime.apiVersionString ?? "",
            DeckLinkRuntime.runtimeIsTooOld)
    }

    func listDisplayModes(devicePersistentID: Int64, reply: @escaping (Data) -> Void) {
        let modes = DeckLinkRuntime.displayModes(persistentID: devicePersistentID)
            .map { mode in
                DeckLinkHelperDisplayMode(
                    name: mode.name,
                    modeID: Int64(mode.modeID),
                    width: mode.width,
                    height: mode.height,
                    frameDuration: mode.frameDuration,
                    timeScale: mode.timeScale,
                    progressive: mode.progressive,
                    supportsKeying: mode.supportsKeying)
            }
        reply((try? JSONEncoder().encode(modes)) ?? Data())
    }

    func startOutput(
        devicePersistentID: Int64,
        width: Int32,
        height: Int32,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        keying: Int32,
        modeID: Int64,
        reply: @escaping (String?, String) -> Void
    ) {
        stopOutput()
        guard DeckLinkRuntime.isAvailable else {
            reply("Desktop Video is not installed (blackmagicdesign.com/support)", "")
            return
        }
        if DeckLinkRuntime.runtimeIsTooOld {
            reply(
                "Desktop Video \(DeckLinkRuntime.apiVersionString ?? "?") is too old — "
                    + "install \(DeckLinkRuntime.requiredAPIMajor).0 or later", "")
            return
        }

        guard DeckLinkRuntime.devices()
            .contains(where: { $0.persistentID == devicePersistentID })
        else {
            reply(
                "DeckLink device not found (unplugged, or Desktop Video "
                    + "not installed)", "")
            return
        }
        let allModes = DeckLinkRuntime.displayModes(persistentID: devicePersistentID)
        let chosenModeID: UInt32
        var chosenViaAuto = false
        if modeID != 0 {
            chosenModeID = UInt32(truncatingIfNeeded: modeID)
        } else {
            guard !allModes.isEmpty else {

                reply(
                    "no playback modes — this connector may be mapped as an "
                        + "input in Desktop Video Setup", "")
                return
            }
            let modes = allModes.filter { keying == 0 || $0.supportsKeying }

            if let configured = DeckLinkRuntime.configuredOutputMode(
                    persistentID: devicePersistentID),
                let cardMode = modes.first(where: {
                    $0.modeID == configured
                        && $0.width == Int(width) && $0.height == Int(height)
                }) {
                chosenModeID = cardMode.modeID
            } else if frameRateDenominator != 0,
                let match = DeckLinkDisplayMode.bestMatch(
                    width: Int(width), height: Int(height),
                    framesPerSecond: Int(frameRateNumerator / frameRateDenominator),
                    in: modes) {
                chosenModeID = match.modeID
            } else {
                reply(
                    "no SDI mode matches \(width)×\(height) at "
                        + "\(frameRateNumerator)/\(frameRateDenominator) fps — "
                        + "choose a Format to send this screen scaled", "")
                return
            }
            chosenViaAuto = true
        }

        var detailParts: [String] = []
        if let name = allModes.first(where: { $0.modeID == chosenModeID })?.name {
            detailParts.append(chosenViaAuto ? "\(name) (Auto)" : name)
        }
        if keying == 2,
            !DeckLinkRuntime.referenceLocked(persistentID: devicePersistentID) {
            detailParts.append("no reference")
        }
        let wireDetail = detailParts.joined(separator: " · ")
        do {

            DeckLinkOutputStore.shared.evict(device: devicePersistentID)
            let output = try DeckLinkOutput(
                persistentID: devicePersistentID,
                modeID: chosenModeID,
                keying: DeckLinkKeying(rawValue: keying) ?? .off)
            device = devicePersistentID
            generation = DeckLinkOutputStore.shared.install(
                device: devicePersistentID, output: output)
            reply(nil, wireDetail)
        } catch DeckLinkError.openFailed(let message) {
            reply(message, "")
        } catch {
            reply("DeckLink output failed: \(error)", "")
        }
    }

    func sendFrame(_ surface: IOSurface, reply: @escaping (Bool) -> Void) {
        guard let device, let generation,
            let output = DeckLinkOutputStore.shared.output(
                device: device, generation: generation)
        else {
            reply(false)
            return
        }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
            let pixelBuffer = unmanaged?.takeRetainedValue()
        else {
            reply(false)
            return
        }
        reply(output.display(pixelBuffer: pixelBuffer))
    }

    func stopOutput() {
        if let device, let generation {
            DeckLinkOutputStore.shared.close(device: device, generation: generation)
        }
        device = nil
        generation = nil
    }

    func listInputDevices(reply: @escaping (Data) -> Void) {
        let devices = DeckLinkRuntime.inputDevices()
            .filter(\.supportsCapture)
            .map { device in
                DeckLinkHelperInputDevice(
                    name: device.name,
                    persistentID: device.persistentID,
                    supportsFormatDetection: device.supportsFormatDetection,
                    usableForCapture: device.isUsableForCapture,
                    captureBusy: device.captureBusy,
                    playbackBusy: device.playbackBusy)
            }
        reply((try? JSONEncoder().encode(devices)) ?? Data())
    }

    func startInput(devicePersistentID: Int64, reply: @escaping (String?) -> Void) {
        stopInput()
        guard DeckLinkRuntime.isAvailable else {
            reply("Desktop Video is not installed (blackmagicdesign.com/support)")
            return
        }
        if DeckLinkRuntime.runtimeIsTooOld {
            reply(
                "Desktop Video \(DeckLinkRuntime.apiVersionString ?? "?") is too old — "
                    + "install \(DeckLinkRuntime.requiredAPIMajor).0 or later")
            return
        }
        guard let port = DeckLinkRuntime.inputDevices()
            .first(where: { $0.persistentID == devicePersistentID })
        else {
            reply("DeckLink device not found (unplugged, or Desktop Video not installed)")
            return
        }
        guard port.supportsCapture, !port.inactive else {
            reply("\(port.name) cannot capture in the card's current profile (Desktop Video Setup)")
            return
        }
        guard port.inputModeCount > 0 else {
            reply("\(port.name) is mapped as an output — map it as an input in Desktop Video Setup")
            return
        }
        do {
            try DeckLinkInputStore.shared.subscribe(
                device: devicePersistentID, token: inputToken
            ) { [weak self] buffer in
                self?.push(buffer)
            }
            inputLock.lock()
            inputDevice = devicePersistentID
            inputError = nil
            inputLock.unlock()
            reply(nil)
        } catch DeckLinkError.openFailed(let message) {
            inputLock.lock()
            inputError = message
            inputLock.unlock()
            reply(message)
        } catch {
            reply("DeckLink capture failed: \(error)")
        }
    }

    func inputStatus(reply: @escaping (Data) -> Void) {
        inputLock.lock()
        let device = inputDevice
        let startError = inputError
        inputLock.unlock()
        var status = DeckLinkHelperInputStatus(signal: .starting)
        if let startError {
            status = DeckLinkHelperInputStatus(signal: .failed, error: startError)
        } else if let device, let state = DeckLinkInputStore.shared.state(device: device) {
            switch state {
            case .noSignal:
                status.signal = .noSignal
            case .receiving(let format):
                status = DeckLinkHelperInputStatus(
                    signal: .receiving, format: format.label,
                    width: format.width, height: format.height)
            case .failed(let message):
                status = DeckLinkHelperInputStatus(signal: .failed, error: message)
            }
        } else if device == nil {
            status = DeckLinkHelperInputStatus(signal: .failed, error: "not capturing")
        }
        reply((try? JSONEncoder().encode(status)) ?? Data())
    }

    func stopInput() {
        inputLock.lock()
        let device = inputDevice
        inputDevice = nil
        inputError = nil
        inputLock.unlock()
        if let device {
            DeckLinkInputStore.shared.unsubscribe(device: device, token: inputToken)
        }
    }

    /// Hands a frame to the app. At most two in flight; the surface's global use count stays
    /// raised until the app answers, so the capture ring never overwrites it mid-flight.
    private func push(_ buffer: CVPixelBuffer) {
        guard let connection,
            let surfaceRef = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return }
        let claimed = framesInFlight.withLock { count -> Bool in
            guard count < 2 else { return false }
            count += 1
            return true
        }
        guard claimed else { return }
        IOSurfaceIncrementUseCount(surfaceRef)
        nonisolated(unsafe) let held = surfaceRef
        let inFlight = framesInFlight
        let release: @Sendable () -> Void = {
            IOSurfaceDecrementUseCount(held)
            inFlight.withLock { $0 -= 1 }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in release() }
        guard let client = proxy as? DeckLinkInputClientProtocol else {
            release()
            return
        }
        client.inputFrame(unsafeBitCast(surfaceRef, to: IOSurface.self)) { release() }
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkInputClientProtocol.self)
        let service = DeckLinkHelperService()
        service.connection = connection
        connection.exportedObject = service
        // A capture must not outlive its app-side owner (app quit, input removed mid-call).
        connection.invalidationHandler = { service.stopInput() }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
