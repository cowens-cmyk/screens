import AppKit
import CoreMedia
import CoreVideo
import Observation
import RenderEngine
import ScreenCaptureKit

// A Web Page video input: a live web page in its own operator window, recorded with
// ScreenCaptureKit and handed to the media engine like an NDI source (`latestFrame`). Window
// capture is used rather than WKWebView snapshots because HTML5 video renders in a separate GPU
// layer that snapshots leave out. Page audio plays from WebKit to the Mac's default output; it is
// not routed into the Mixer.

@MainActor
@Observable
final class WebInputSource {
    enum State: Equatable {
        case starting
        case needsPermission
        case capturing
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var width: Int
    private(set) var height: Int
    private(set) var framesPerSecond: Int

    @ObservationIgnored let frames = Locked<CVPixelBuffer?>(nil)
    @ObservationIgnored private let window: WebInputWindowController
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: WebStreamOutput?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let name: String

    var onMuteChanged: ((Bool) -> Void)? {
        get { window.onMuteChanged }
        set { window.onMuteChanged = newValue }
    }

    private static var requestedPermission = false

    init(name: String, url: String, width: Int, height: Int, framesPerSecond: Int, muted: Bool) {
        self.name = name
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        window = WebInputWindowController(
            title: Self.windowTitle(name),
            pixelSize: CGSize(width: width, height: height), muted: muted)
        window.onBackingChanged = { [weak self] in self?.matchBacking() }
        window.load(url)
    }

    var isReceiving: Bool {
        state == .capturing && frames.value != nil
    }

    func start() {
        stopped = false
        window.showWindow(nil)
        window.window?.orderFront(nil)
        if !CGPreflightScreenCaptureAccess(), !Self.requestedPermission {
            Self.requestedPermission = true
            CGRequestScreenCaptureAccess()
        }
        restartCapture()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        endStream()
        frames.value = nil
        window.teardown()
        DiagnosticsStore.shared.note("input.web", detail: "stopped: \(name)")
    }

    func showWindow() {
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func load(_ url: String) {
        window.load(url)
    }

    func rename(_ name: String) {
        window.window?.title = Self.windowTitle(name)
    }

    func setMuted(_ muted: Bool) {
        window.setMuted(muted)
    }

    func reconfigure(width: Int, height: Int, framesPerSecond: Int) {
        guard width != self.width || height != self.height || framesPerSecond != self.framesPerSecond
        else { return }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        window.resize(pixelSize: CGSize(width: width, height: height))
        restartCapture()
    }

    // Picks the capture back up once Screen Recording is granted — polled by the inventory.
    func retryIfPermitted() {
        guard !stopped, state == .needsPermission, CGPreflightScreenCaptureAccess() else { return }
        restartCapture()
    }

    private func matchBacking() {
        guard !stopped else { return }
        window.resize(pixelSize: CGSize(width: width, height: height))
        restartCapture()
    }

    private func restartCapture() {
        generation += 1
        let token = generation
        endStream()
        guard CGPreflightScreenCaptureAccess() else {
            setState(.needsPermission)
            DiagnosticsStore.shared.note(
                "input.web",
                detail: "Screen Recording permission needed — enable in System Settings › Privacy & Security › Screen & System Audio Recording: \(name)")
            return
        }
        setState(.starting)
        Task { @MainActor [weak self] in await self?.beginCapture(token: token) }
    }

    private func beginCapture(token: Int) async {
        guard let nsWindow = window.window else { return }
        let windowID = CGWindowID(nsWindow.windowNumber)
        var target: SCWindow?
        // A freshly ordered-in window can take a moment to appear in the shareable list.
        for _ in 0..<10 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                target = content.windows.first { $0.windowID == windowID }
            } catch {
                guard token == generation else { return }
                fail("shareable content unavailable: \(error.localizedDescription)")
                return
            }
            if target != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
            guard token == generation else { return }
        }
        guard token == generation else { return }
        guard let target else {
            fail("window not found for capture")
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.sourceRect = window.pageRect(capturedWindowHeight: filter.contentRect.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.queueDepth = 6
        configuration.capturesAudio = false

        let output = WebStreamOutput(frames: frames) { [weak self] message in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.fail(message)
                // A dropped stream (display change, window server hiccup) comes back on its own.
                try? await Task.sleep(for: .seconds(3))
                guard token == self.generation, !self.stopped else { return }
                self.restartCapture()
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            guard token == generation else { return }
            fail("capture failed: \(error.localizedDescription)")
            return
        }
        guard token == generation else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.output = output
        setState(.capturing)
        DiagnosticsStore.shared.note(
            "input.web", detail: "capturing \(width)x\(height)@\(framesPerSecond): \(name)")
    }

    private func endStream() {
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        output = nil
    }

    private func fail(_ message: String) {
        setState(.failed(message))
        DiagnosticsStore.shared.note("input.web", detail: "\(message): \(name)")
    }

    private func setState(_ new: State) {
        state = new
        window.page.needsPermission = new == .needsPermission
        window.page.status = Self.statusText(new, width: width, height: height, fps: framesPerSecond)
    }

    static func statusText(_ state: State, width: Int, height: Int, fps: Int) -> String {
        switch state {
        case .starting: return "Starting capture\u{2026}"
        case .needsPermission: return "Screen Recording permission needed"
        case .capturing: return "Capturing \(width)\u{D7}\(height) at \(fps) fps"
        case .failed(let message): return "Capture stopped — \(message)"
        }
    }

    private static func windowTitle(_ name: String) -> String {
        "Web Input \u{2014} \(name)"
    }
}

// Receives ScreenCaptureKit frames off the main thread and keeps only the newest complete one.
private final class WebStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mxu.webinput.capture", qos: .userInteractive)
    private let frames: Locked<CVPixelBuffer?>
    private let onError: @Sendable (String) -> Void

    init(frames: Locked<CVPixelBuffer?>, onError: @escaping @Sendable (String) -> Void) {
        self.frames = frames
        self.onError = onError
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        frames.value = pixelBuffer
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError("capture interrupted: \(error.localizedDescription)")
    }
}
