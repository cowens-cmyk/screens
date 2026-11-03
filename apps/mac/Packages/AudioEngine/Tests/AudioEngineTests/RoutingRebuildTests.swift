import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func tone(seconds: Double, name: String) throws -> URL {
    let sampleRate = 44_100.0
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-engine-routing-\(name).wav")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
          let buffer = AVAudioPCMBuffer(
              pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate))
    else { throw AudioEngineError.emptySchedule(url) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    buffer.frameLength = buffer.frameCapacity
    for index in 0 ..< Int(buffer.frameLength) {
        let sample = Float(sin(2 * .pi * 440 * Double(index) / sampleRate)) * 0.1
        buffer.floatChannelData?[0][index] = sample
        buffer.floatChannelData?[1][index] = sample
    }
    try file.write(from: buffer)
    return url
}

@Test func reapplyingTheSameOutputLeavesPlaybackAlone() async throws {
    let url = try tone(seconds: 6, name: "same")
    let engine = AudioEngine()
    engine.masterVolume = 0
    // No output hardware on this Mac (CI): nothing to route.
    guard AudioDeviceList.defaultOutputDevice() != nil,
          (try? engine.setOutputDevice(nil)) != nil,
          (try? engine.play(url: url)) != nil
    else { return }
    let before = engine.routingRebuildsForTests
    try engine.setOutputDevice(nil)
    try engine.setOutputDevice(nil)
    #expect(engine.routingRebuildsForTests == before, "an unchanged device does not restart the engine")
    engine.stop()
}

@Test func rebuildingKeepsTheTrackInAndOutPoints() async throws {
    let url = try tone(seconds: 10, name: "trim")
    let engine = AudioEngine()
    engine.masterVolume = 0
    guard AudioDeviceList.defaultOutputDevice() != nil,
          (try? engine.play(url: url, trimStart: 2, trimEnd: 5)) != nil
    else { return }
    try await Task.sleep(for: .milliseconds(200))
    // A different channel offset forces a full stop and rebuild.
    try? engine.setOutputDevice(nil, channelOffset: 2)
    #expect(abs((engine.position?.duration ?? 0) - 5) < 0.05, "the out point survives a rebuild")
    engine.seek(to: 0)
    #expect((engine.position?.elapsed ?? 0) >= 2, "the in point survives a rebuild")
    engine.stop()
}

@Test func stoppingWithAFadeKeepsTheEngineUntilTheFadeEnds() async throws {
    let url = try tone(seconds: 6, name: "fade")
    var engine: AudioEngine? = AudioEngine()
    engine?.masterVolume = 0
    guard AudioDeviceList.defaultOutputDevice() != nil,
          (try? engine?.play(url: url)) != nil
    else { return }
    try await Task.sleep(for: .milliseconds(200))
    weak let released = engine
    engine?.stop(fade: 0.5)
    engine = nil
    #expect(released != nil, "the fade holds the engine after its owner lets go")
    try await Task.sleep(for: .milliseconds(1200))
    #expect(released == nil, "the engine is freed once the fade is done")
}
