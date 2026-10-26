import CoreGraphics
import Foundation
import ImageIO
import Metal
import RenderEngine
import Testing
import UniformTypeIdentifiers
import simd
@testable import PresenterCore
@testable import SlideScene

// The stage display rendered the way the stage screen draws it: the Video
// layout over a placeholder video frame, the Message layout, and the
// Worship layout before and after its redesign. Each must draw something;
// set STAGE_EVIDENCE_DIR to keep them as PNGs to look at.

/// A solid placeholder for the playing video, served as library media is.
private final class PlaceholderVideo: MediaTextureSource, @unchecked Sendable {
    private var surfaces: [String: MediaSurface] = [:]

    init(device: MTLDevice) {
        let width = 160, height = 90
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let texture = device.makeTexture(descriptor: {
                  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                  descriptor.usage = .shaderRead
                  return descriptor
              }())
        else { return }
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.32, blue: 0.52, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.28, green: 0.46, blue: 0.70, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
        guard let data = context.data else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        surfaces["clip"] = .bgra(texture: texture, transform: VideoColorTransform(
            ycbcrMatrix: matrix_identity_float3x3, ycbcrOffset: .zero,
            gamutToWorking: matrix_identity_float3x3, premultipliedAlpha: true), retained: [])
    }

    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { surfaces[mediaID] }
    func liveCadence(for mediaID: String) -> LiveCadence? { nil }
}

@MainActor
private struct StageRenderer {
    let compositor: Compositor
    let source: PlaceholderVideo
    static let size = (width: 1600, height: 900)

    init?() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        compositor = try Compositor(device: device)
        source = PlaceholderVideo(device: device)
        compositor.mediaSource = source
    }

    /// Renders the scene, checks it drew something, and keeps it when asked.
    func render(_ scene: RenderScene, _ name: String) throws {
        let frame = try compositor.renderFrame(scene: scene, width: Self.size.width, height: Self.size.height)
        #expect(litPixels(frame) > 2000, "\(name) drew something")
        save(frame, name)
    }
}

private func litPixels(_ frame: RenderedFrame) -> Int {
    var lit = 0
    frame.data.withUnsafeBytes { raw in
        for y in stride(from: 0, to: frame.height, by: 2) {
            for x in stride(from: 0, to: frame.width, by: 2) {
                let pixel = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
                if Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2]) > 0.3 { lit += 1 }
            }
        }
    }
    return lit
}

private func save(_ frame: RenderedFrame, _ name: String) {
    guard let folder = ProcessInfo.processInfo.environment["STAGE_EVIDENCE_DIR"], !folder.isEmpty,
          let image = frame.cgImage,
          let context = CGContext(
            data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    guard let flat = context.makeImage() else { return }
    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, flat, nil)
    CGImageDestinationFinalize(destination)
}

private let at = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 11, minute: 42, second: 10))!

private func audience() -> RenderScene {
    var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    scene.addItem(RenderItem(
        id: "video-1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        content: .media(id: "clip", scaleMode: .fill, sourceRect: nil)
    ), to: .videos)
    return scene
}

private let sermonTimer = TimerSnapshot(
    id: SermonTimer.id, name: SermonTimer.name, mode: .countdown, isRunning: true,
    runningSince: at.addingTimeInterval(-600), banked: 1166, durationSeconds: 2400)

private let playing = VideoCountdown(
    name: "Announcements", duration: 240, position: 79, anchoredAt: at, isPlaying: true)

private let amazingGrace = ConfidenceInfo.SlideText(
    body: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
    musicKey: "G")
private let withChords = ConfidenceInfo.SlideText(
    body: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
    chords: [
        ChordPlacement(line: 0, column: 0, symbol: "G"),
        ChordPlacement(line: 0, column: 15, symbol: "G7"),
        ChordPlacement(line: 0, column: 24, symbol: "C"),
        ChordPlacement(line: 0, column: 30, symbol: "G"),
        ChordPlacement(line: 1, column: 0, symbol: "G"),
        ChordPlacement(line: 1, column: 13, symbol: "Em"),
        ChordPlacement(line: 1, column: 21, symbol: "D"),
    ],
    musicKey: "G")
private let nextLines = ConfidenceInfo.SlideText(
    body: "I once was lost, but now am found\nWas blind, but now I see",
    chords: [
        ChordPlacement(line: 0, column: 0, symbol: "G"),
        ChordPlacement(line: 0, column: 17, symbol: "G/B"),
        ChordPlacement(line: 1, column: 0, symbol: "C"),
        ChordPlacement(line: 1, column: 19, symbol: "G"),
    ],
    musicKey: "G")
private let longLines = ConfidenceInfo.SlideText(
    body: "When we've been there ten thousand years, bright shining as the sun\nWe've no less days to sing God's praise than when we'd first begun\nPraise God, praise God",
    musicKey: "G")

private func worshipInfo(current: ConfidenceInfo.SlideText, next: ConfidenceInfo.SlideText?, group: String) -> ConfidenceInfo {
    ConfidenceInfo(
        current: current, next: next, currentGroupName: group, currentPresentationName: "Amazing Grace")
}

@MainActor
struct StageEvidenceTests {

    @Test func theVideoStageRenders() throws {
        guard let renderer = try StageRenderer() else { return }
        let layout = ConfidenceLayoutTemplate.video.make(name: "Video")
        let worship = ConfidenceLayoutTemplate.worship.make(name: "Worship")
        let message = ConfidenceLayoutTemplate.sermon.make(name: "Message")

        let worshipInfo = worshipInfo(current: amazingGrace, next: nextLines, group: "Verse 1")
        var duringWorship = worshipInfo
        duringWorship.videoCountdown = playing
        try renderer.render(StageScenes.scene(
            override: nil, source: .layout(worship),
            video: StageVideoPlan(layout: layout, isMessage: false),
            info: duringWorship, at: at, audience: audience), "video-in-worship")

        let messageInfo = ConfidenceInfo(timers: [sermonTimer])
        var duringMessage = messageInfo
        duringMessage.videoCountdown = playing
        try renderer.render(StageScenes.scene(
            override: nil, source: .layout(message),
            video: StageVideoPlan(layout: layout, isMessage: true),
            info: duringMessage, at: at, audience: audience), "video-during-message")

        try renderer.render(StageScenes.scene(
            override: nil, source: .layout(message),
            video: StageVideoPlan(layout: layout, isMessage: true),
            info: messageInfo, at: at, audience: audience), "message-regular")

        // After the video: the same layout, the timer a full video later.
        let after = at.addingTimeInterval(playing.duration - playing.position)
        try renderer.render(StageScenes.scene(
            override: nil, source: .layout(message),
            video: StageVideoPlan(layout: layout, isMessage: true),
            info: duringMessage, at: after, audience: audience), "message-after-video")

        var withMessage = duringMessage
        withMessage.alert = CueAlert(message: "Wrap up in 2", behavior: .persist, target: .confidence, firedAt: at.addingTimeInterval(-3))
        try renderer.render(StageScenes.scene(
            override: nil, source: .layout(message),
            video: StageVideoPlan(layout: layout, isMessage: true),
            info: withMessage, at: at, audience: audience), "video-during-message-stage-message")
    }

    @Test func theWorshipStageRendersBeforeAndAfter() throws {
        guard let renderer = try StageRenderer() else { return }
        let before = ConfidenceLayoutTemplate.legacyWorship(name: "Worship")
        let after = ConfidenceLayoutTemplate.worship.make(name: "Worship")
        let cases: [(String, ConfidenceInfo)] = [
            ("lyrics", worshipInfo(
                current: ConfidenceInfo.SlideText(body: amazingGrace.body, musicKey: "G"),
                next: ConfidenceInfo.SlideText(body: nextLines.body, musicKey: "G"), group: "Verse 1")),
            ("chords", worshipInfo(current: withChords, next: nextLines, group: "Verse 1")),
            ("long-lines", worshipInfo(current: longLines, next: amazingGrace, group: "Verse 4")),
            ("last-slide", worshipInfo(current: amazingGrace, next: nil, group: "Ending")),
        ]
        for (name, info) in cases {
            try renderer.render(ConfidenceSceneBuilder.scene(layout: before, info: info, at: at), "worship-before-\(name)")
            try renderer.render(ConfidenceSceneBuilder.scene(layout: after, info: info, at: at), "worship-after-\(name)")
        }
        var message = cases[1].1
        message.alert = CueAlert(message: "Repeat the chorus", behavior: .persist, target: .confidence, firedAt: at.addingTimeInterval(-5))
        try renderer.render(ConfidenceSceneBuilder.scene(layout: after, info: message, at: at), "worship-after-stage-message")
    }
}
