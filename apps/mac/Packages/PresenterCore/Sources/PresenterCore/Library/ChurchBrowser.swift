import Foundation

/// The Browser: a web page the operator drives in its own window, shown on
/// the screens while its slide is live.
///
/// It is a Web Page live input with a fixed id, so the one shared Browser
/// presentation (a single slide filled edge to edge by that input) finds it
/// on every Mac. Each Mac makes its own input the first time it's opened
/// there; the presentation is the church's, made once.
public enum ChurchBrowser {
    public static let inputID = "browser"
    public static let inputName = "Browser"
    public static let startPage = "https://hopejc.org"

    public static let presentationID = "browser"
    public static let presentationName = "Browser"

    /// The Browser presentation in the library: the one with the fixed id,
    /// else one with its name.
    public static func find(ids: [(id: String, name: String)]) -> String? {
        if ids.contains(where: { $0.id == presentationID }) { return presentationID }
        return ids.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == presentationName.lowercased() }
            .map(\.id).sorted().first
    }

    /// One slide, the page filling it. Black behind, so the screen is dark
    /// rather than showing the slide underneath before the first frame.
    public static func presentation(width: Int = 1920, height: Int = 1080) -> Presentation {
        let page = SlideObject(
            id: "browser-page", objectKind: .shape, name: "Browser", text: "",
            x: 0, y: 0, width: Double(width), height: Double(height),
            fill: ObjectFill(fillKind: .media, liveInputId: inputID))
        let slide = Slide(
            id: "browser-slide", name: "Browser", objects: [page],
            backgroundFill: ObjectFill(fillKind: .solid, colorHex: "#000000FF"))
        return Presentation(
            id: presentationID, name: presentationName, presentationKind: .deck, themeId: "",
            slides: [slide], canvasWidth: width, canvasHeight: height)
    }

    /// Whether a slide shows the Browser: it goes up, so its window comes
    /// to the front for the operator to drive.
    public static func shows(_ slide: Slide) -> Bool {
        slide.objects.contains { $0.fill?.liveInputId == inputID }
    }
}
