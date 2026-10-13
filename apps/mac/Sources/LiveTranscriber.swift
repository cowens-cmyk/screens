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
    /// Input level, 0…1, a few times a second — proof the right mic is live.
    var onLevel: ((Float) -> Void)?
    var onState: ((State) -> Void)?

    private var hub: AudioInputHub?
    private var hubUID: String?
    private var tapToken: UUID?
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Every input Core Audio knows: built-in and USB mics, audio
    /// interfaces, Dante and aggregate devices.
    static func inputDevices() -> [(uid: String, name: String, channels: Int)] {
        AudioDeviceList.inputDevices().map { ($0.uid, $0.name, $0.channelCount) }
    }

    func start(deviceUID: String, channels: InputChannelSelection = .default) {
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
            let levels = LevelMeter { [weak self] level in
                Task { @MainActor in self?.onLevel?(level) }
            }
            tapToken = hub.addTap(channels: channels) { buffer, _, _ in
                levels.measure(buffer)
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

/// Peak level of the incoming audio, reported about ten times a second.
private final class LevelMeter: @unchecked Sendable {
    private let report: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var peak: Float = 0
    private var last = Date.distantPast

    init(report: @escaping @Sendable (Float) -> Void) { self.report = report }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        var loudest: Float = 0
        for index in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[index])) }
        lock.lock()
        peak = max(peak, loudest)
        let due = Date().timeIntervalSince(last) > 0.1
        let value = peak
        if due { peak = 0; last = Date() }
        lock.unlock()
        if due { report(min(1, value)) }
    }
}
