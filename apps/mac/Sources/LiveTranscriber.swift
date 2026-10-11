import AudioEngine
import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text from one of this Mac's audio inputs (the worship
/// leader's vocal mic, or the pastor's), using SpeechAnalyzer.
@MainActor
final class LiveTranscriber {
    enum State: Equatable { case idle, preparing, listening, failed(String) }

    private(set) var state: State = .idle
    var onText: ((_ text: String, _ isFinal: Bool) -> Void)?
    var onState: ((State) -> Void)?

    private var hub: AudioInputHub?
    private var hubUID: String?
    private var tapToken: UUID?
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    static func inputDevices() -> [(uid: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }

    func start(deviceUID: String) {
        stop()
        guard #available(macOS 26, *) else {
            set(.failed("Live listening needs macOS 26 or newer."))
            return
        }
        set(.preparing)
        do {
            let hub = try AudioInputHubPool.shared.acquire(deviceUID: deviceUID)
            self.hub = hub
            hubUID = deviceUID
            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
            self.continuation = continuation
            tapToken = hub.addTap(channels: .default) { buffer, _, _ in
                continuation.yield(buffer)
            }
            task = Task { [weak self] in await self?.run(buffers: stream) }
        } catch {
            set(.failed("Couldn't open that input: \(error)"))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        if let hub, let tapToken { hub.removeTap(tapToken) }
        if let hubUID { AudioInputHubPool.shared.release(deviceUID: hubUID) }
        hub = nil
        hubUID = nil
        tapToken = nil
        if state != .idle { set(.idle) }
    }

    private func set(_ state: State) {
        self.state = state
        onState?(state)
    }

    @available(macOS 26, *)
    private func run(buffers: AsyncStream<AVAudioPCMBuffer>) async {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                set(.failed("No speech model is available for English."))
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputs)
            set(.listening)

            let results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run { self?.onText?(text, result.isFinal) }
                    }
                } catch {}
            }
            var converter: AVAudioConverter?
            for await buffer in buffers {
                if Task.isCancelled { break }
                if converter == nil || converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converter, let converted = Self.convert(buffer, with: converter, to: format) else { continue }
                feed.yield(AnalyzerInput(buffer: converted))
            }
            feed.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            results.cancel()
        } catch {
            set(.failed("Speech recognition stopped: \(error.localizedDescription)"))
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
