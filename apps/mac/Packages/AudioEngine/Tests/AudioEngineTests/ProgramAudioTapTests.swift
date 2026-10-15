import AVFoundation
import Foundation
import Testing

@testable import AudioEngine

private final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(frames: AVAudioFrameCount, seconds: Double, receivedAt: Double)] = []
    var count: Int { lock.withLock { received.count } }
    var first: (frames: AVAudioFrameCount, seconds: Double, receivedAt: Double)? {
        lock.withLock { received.first }
    }
    func add(frames: AVAudioFrameCount, seconds: Double) {
        lock.withLock { received.append((frames, seconds, CACurrentMediaTime())) }
    }
}

@available(macOS 14.2, *)
@Test(.enabled(if: hasAudioOutputDevice(), "No default audio output device"), .disabled(if: isVirtualMachine(), "a virtual machine has no host audio clock: the tap delivered nothing in 186 s on GitHub's runner"))
func programTapDeliversCopiedBuffersOnTheHostClock() async throws {
    let box = BufferBox()
    let tap = try ProgramAudioTap { buffer, _, hostSeconds in
        box.add(frames: buffer.frameLength, seconds: hostSeconds)
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    engine.mainMixerNode.outputVolume = 0
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    let tone = try #require(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate) / 10))
    tone.frameLength = tone.frameCapacity
    for channel in 0 ..< Int(format.channelCount) {
        let data = try #require(tone.floatChannelData?[channel])
        for frame in 0 ..< Int(tone.frameLength) {
            data[frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate)) * 0.1
        }
    }
    try engine.start()
    player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
    player.play()
    defer { engine.stop() }

    for _ in 0 ..< 30 where box.count < 3 {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    withExtendedLifetime(tap) {}
    #expect(box.count >= 3, "IO proc never ticked")
    let first = try #require(box.first)
    #expect(first.frames > 0)
    #expect(first.seconds > 0)
    #expect(abs(first.seconds - first.receivedAt) < 0.1,
            "tap timestamp must be within 100 ms of its callback on the host clock")
}

private func isVirtualMachine() -> Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let read = sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0)
    return read == 0 && present != 0
}
