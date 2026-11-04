import AVFoundation
import AudioEngine
import MediaToolbox
import RenderEngine

final class VideoAudioTap {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    /// A fade to silence, on the host clock.
    struct FadeOut: Sendable, Equatable {
        var startHostTime: CFTimeInterval
        var duration: Double

        func gain(at hostTime: CFTimeInterval) -> Float {
            Float(min(max(1 - (hostTime - startHostTime) / duration, 0), 1))
        }
    }

    /// Scales float samples in place from `from` to `to` across the buffer,
    /// so the fade has no steps in it.
    static func ramp(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, from: Float, to: Float) {
        guard frames > 0 else { return }
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frames * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            let step = (to - from) / Float(frames)
            for index in 0..<count {
                samples[index] *= from + step * Float(index / channels)
            }
        }
    }

    final class Context {
        let sink: Locked<Sink?>

        let delay: Locked<Double>

        let fade: Locked<FadeOut?>

        private let line = AudioDelayLine()
        private(set) var tapFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2)!

        init(sink: Locked<Sink?>, delay: Locked<Double>, fade: Locked<FadeOut?> = Locked(nil)) {
            self.sink = sink
            self.delay = delay
            self.fade = fade
        }

        /// Fades the buffer the player is about to play, when its video is
        /// leaving the screens. Only float samples, which is what a tap is
        /// handed.
        func applyFade(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            guard let fade = fade.value, tapFormat?.commonFormat == .pcmFormatFloat32,
                  let rate = tapFormat?.sampleRate, rate > 0
            else { return }
            let now = CACurrentMediaTime()
            VideoAudioTap.ramp(
                buffers, frames: frames,
                from: fade.gain(at: now), to: fade.gain(at: now + Double(frames) / rate))
        }

        func prepare(format: AVAudioFormat) {
            tapFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }

        func unprepare() {
            converter = nil
            tapFormat = nil
        }

        var isIdle: Bool { sink.value == nil && delay.value == 0 }

        func handle(_ source: AVAudioPCMBuffer) {
            if let sink = sink.value, let converter {
                feed(sink, converting: source, with: converter)
            }
            let milliseconds = delay.value

            if milliseconds > 0, source.format.commonFormat == .pcmFormatFloat32,
               !source.format.isInterleaved {
                line.delayMilliseconds = milliseconds
                line.process(source)
            }
        }

        private func feed(
            _ sink: Sink, converting source: AVAudioPCMBuffer, with converter: AVAudioConverter
        ) {
            let ratio = outputFormat.sampleRate / source.format.sampleRate
            let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: capacity)
            else { return }
            nonisolated(unsafe) var fed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            if conversionError == nil, converted.frameLength > 0 {
                sink(converted)
            }
        }
    }

    @discardableResult
    static func attach(
        to item: AVPlayerItem, sink: Locked<Sink?>, delay: Locked<Double>,
        fade: Locked<FadeOut?> = Locked(nil)
    ) -> Bool {
        guard let track = item.asset.tracks(withMediaType: .audio).first else {
            return false
        }
        let context = Context(sink: sink, delay: delay, fade: fade)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(
                Unmanaged.passRetained(context).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, processingFormat in
                let context = Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var asbd = processingFormat.pointee
                if let format = AVAudioFormat(streamDescription: &asbd) {
                    context.prepare(format: format)
                }
            },
            unprepare: { tap in
                Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

                RealtimeAudioCallback.scope {
                    let status = MTAudioProcessingTapGetSourceAudio(
                        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                    let context = Unmanaged<Context>.fromOpaque(
                        MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    if status == noErr, numberFramesOut.pointee > 0 {
                        context.applyFade(
                            UnsafeMutableAudioBufferListPointer(bufferListInOut),
                            frames: Int(numberFramesOut.pointee))
                    }
                    if status == noErr, !context.isIdle, numberFramesOut.pointee > 0,
                       let tapFormat = context.tapFormat,
                       let source = AVAudioPCMBuffer(
                           pcmFormat: tapFormat, bufferListNoCopy: bufferListInOut) {
                        source.frameLength = AVAudioFrameCount(numberFramesOut.pointee)
                        context.handle(source)
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(context).release()  
            return false
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }
}
