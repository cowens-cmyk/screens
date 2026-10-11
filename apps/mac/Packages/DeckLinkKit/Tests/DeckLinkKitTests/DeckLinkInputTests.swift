import CDeckLink
import CoreVideo
import Testing

@testable import DeckLinkKit

@Test func inputEnumerationDegradesGracefully() {
    let devices = DeckLinkRuntime.inputDevices()
    if !DeckLinkRuntime.isAvailable {
        #expect(devices.isEmpty)
    }
    for device in devices {
        #expect(!device.name.isEmpty)
    }
}

@Test func openingAMissingInputFailsWithAMessage() {
    #expect(throws: DeckLinkError.self) {
        _ = try DeckLinkInputSource(persistentID: .min)
    }
}

@Test func inputPortsMappedAsOutputAreNotOffered() {
    let mappedAsOutput = DeckLinkInputDevice(
        name: "DeckLink 8K Pro (3)", persistentID: 3, supportsCapture: true,
        supportsFormatDetection: true, inactive: false, inputModeCount: 0,
        captureBusy: false, playbackBusy: false)
    #expect(!mappedAsOutput.isUsableForCapture)
    let input = DeckLinkInputDevice(
        name: "DeckLink 8K Pro (2)", persistentID: 2, supportsCapture: true,
        supportsFormatDetection: true, inactive: false, inputModeCount: 40,
        captureBusy: false, playbackBusy: false)
    #expect(input.isUsableForCapture)
}

@Test func formatLabelsReadLikeBroadcastNames() {
    let progressive: UInt32 = 0x7072_6F67
    let upper: UInt32 = 0x7570_7072
    let psf: UInt32 = 0x7073_6620
    #expect(DeckLinkInputFormat(
        width: 1920, height: 1080, frameDuration: 1001, timeScale: 60000,
        fieldDominance: progressive, pixelFormat: 0).label == "1080p59.94")
    #expect(DeckLinkInputFormat(
        width: 1920, height: 1080, frameDuration: 1001, timeScale: 30000,
        fieldDominance: upper, pixelFormat: 0).label == "1080i59.94")
    #expect(DeckLinkInputFormat(
        width: 3840, height: 2160, frameDuration: 1000, timeScale: 50000,
        fieldDominance: progressive, pixelFormat: 0).label == "2160p50")
    #expect(DeckLinkInputFormat(
        width: 1920, height: 1080, frameDuration: 1001, timeScale: 24000,
        fieldDominance: psf, pixelFormat: 0).label == "1080PsF23.98")
}

@Test func uyvyFramesBecomeBGRA() throws {
    let receiver = DeckLinkInputSource.Receiver(onFrame: nil)
    let width = 4
    let height = 2
    // 2vuy: Cb Y0 Cr Y1. Video-range white (235) and black (16), neutral chroma.
    var bytes = [UInt8]()
    for _ in 0..<height { bytes += [128, 235, 128, 235, 128, 16, 128, 16] }
    bytes.withUnsafeBufferPointer { pointer in
        var frame = DLKInputFrame()
        frame.bytes = pointer.baseAddress
        frame.rowBytes = width * 2
        frame.width = Int32(width)
        frame.height = Int32(height)
        frame.pixelFormat = 0x3276_7579
        frame.colorspace = 0x7237_3039
        receiver.receive(frame)
    }
    let buffer = try #require(receiver.latest())
    #expect(CVPixelBufferGetWidth(buffer) == width)
    #expect(CVPixelBufferGetIOSurface(buffer) != nil)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [255, 255, 255, 255])
    #expect(Array(UnsafeBufferPointer(start: pixels + 8, count: 4)) == [0, 0, 0, 255])
}
