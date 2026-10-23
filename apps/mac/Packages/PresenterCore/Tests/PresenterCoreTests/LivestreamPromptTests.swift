import Foundation
import Testing

@testable import PresenterCore

private func pictureSlide(_ id: String, media: String = "img", design: StreamDesign? = nil) -> Slide {
    Slide(id: id, name: id, objects: [], background: CueMedia(mediaId: media), streamDesign: design)
}

private let library: [String: MediaKind] = ["img": .image, "vid": .video]

@Test func newPictureAndVideoSlidesAsk() {
    let added = [pictureSlide("a"), pictureSlide("b", media: "vid")]
    #expect(LivestreamPrompt.slidesToAsk(added: added, skipped: false) { library[$0] } == ["a", "b"])
}

@Test func textSlidesNeverAsk() {
    let lyric = Slide(id: "l", name: "", objects: [
        SlideObject(id: "t", objectKind: .text, name: "", text: "Amazing grace"),
    ])
    var lyricOverPicture = pictureSlide("lp")
    lyricOverPicture.objects = [SlideObject(id: "t", objectKind: .text, name: "", text: "How sweet the sound")]
    var emptyBox = pictureSlide("e")
    emptyBox.objects = [SlideObject(id: "t", objectKind: .text, name: "", text: "  \n")]
    let asked = LivestreamPrompt.slidesToAsk(added: [lyric, lyricOverPicture, emptyBox], skipped: false) { library[$0] }
    #expect(asked == ["e"], "an empty text box is still a picture slide")
}

@Test func slidesThatAlreadyChoseOrHaveNoLibraryMediaDontAsk() {
    let chosen = pictureSlide("c", design: .lowerThirdImage("png"))
    let missing = pictureSlide("m", media: "gone")
    let blank = Slide(id: "b", name: "", objects: [])
    #expect(LivestreamPrompt.slidesToAsk(added: [chosen, missing, blank], skipped: false) { library[$0] }.isEmpty)
}

@Test func aPresentationThatSaidDontAskNeverAsks() {
    #expect(LivestreamPrompt.slidesToAsk(added: [pictureSlide("a")], skipped: true) { library[$0] }.isEmpty)
}

@Test func eachAnswerIsTheSameChoiceTheMenusMake() {
    #expect(LivestreamPrompt.design(for: .themeDefault) == nil)
    #expect(LivestreamPrompt.design(for: .fullScreen)?.mode == .audience)
    #expect(LivestreamPrompt.design(for: .nothing)?.mode == .clear)
    let image = LivestreamPrompt.design(for: .lowerThirdImage(mediaID: "png"))
    #expect(image?.mode == .design)
    #expect(image?.lowerThirdImageID == "png")
    #expect(image?.themeId == nil)
}

@Test func aSlideSavedBeforeLowerThirdImagesDecodesUnchanged() throws {
    let json = #"{"id":"s","name":"","objects":[],"streamDesign":{"category":"","mode":"design","themeId":"t","slideId":"d"}}"#
    let slide = try JSONDecoder().decode(Slide.self, from: Data(json.utf8))
    #expect(slide.streamDesign == StreamDesign(category: "", mode: .design, themeId: "t", slideId: "d"))
    #expect(slide.streamDesign?.mediaId == nil)
    #expect(slide.streamDesign?.lowerThirdImageID == nil)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slide)) as? [String: Any]
    let design = encoded?["streamDesign"] as? [String: Any]
    #expect(design?["mediaId"] == nil, "no new key written for a slide without a picture")
}

@Test func aLowerThirdImageRoundTripsAndOlderBuildsReadALowerThird() throws {
    let slide = pictureSlide("s", design: .lowerThirdImage("png"))
    let data = try JSONEncoder().encode(slide)
    #expect(try JSONDecoder().decode(Slide.self, from: data) == slide)
    let design = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["streamDesign"] as? [String: Any]
    #expect(design?["mode"] as? String == "design", "a mode every build knows")
}

@Test func theLowerThirdImageIsTheSlidesMedia() {
    let slide = pictureSlide("s", design: .lowerThirdImage("png"))
    #expect(MediaReferences.ids(in: slide) == ["img", "png"])
}
