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
        var slide = self.slide(site: nil, width: Double(width), height: Double(height))
        slide.id = "browser-slide"
        slide.objects[0].id = "browser-page"
        return Presentation(
            id: presentationID, name: presentationName, presentationKind: .deck, themeId: "",
            slides: [slide], canvasWidth: width, canvasHeight: height)
    }

    /// A Browser slide for any presentation: the Browser window filling it,
    /// and the site it opens when it goes live. Nil leaves the window on
    /// whatever page it's showing.
    public static func slide(
        site: String?, width: Double = 1920, height: Double = 1080, id: String = UUID().uuidString
    ) -> Slide {
        let site = site.flatMap(normalized)
        let page = SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: "Browser", text: "",
            x: 0, y: 0, width: width, height: height,
            fill: ObjectFill(fillKind: .media, liveInputId: inputID, browserURL: site))
        return Slide(
            id: id, name: site.map(siteName) ?? "Browser", objects: [page],
            backgroundFill: ObjectFill(fillKind: .solid, colorHex: "#000000FF"))
    }

    /// The site a Browser slide opens, if it names one.
    public static func site(on slide: Slide) -> String? {
        slide.objects.lazy.compactMap { object -> String? in
            guard let fill = object.fill, fill.liveInputId == inputID,
                  let url = fill.browserURL, !url.isEmpty else { return nil }
            return url
        }.first
    }

    /// The slide opening `site` instead (nil: none). Every Browser object on
    /// it gets it; a slide named after its old site takes the new one's name.
    public static func setting(site: String?, on slide: Slide) -> Slide {
        let site = site.flatMap(normalized)
        var slide = slide
        let old = self.site(on: slide)
        for index in slide.objects.indices where slide.objects[index].fill?.liveInputId == inputID {
            slide.objects[index].fill?.browserURL = site
        }
        if slide.name.isEmpty || slide.name == "Browser" || old.map(siteName) == slide.name {
            slide.name = site.map(siteName) ?? "Browser"
        }
        return slide
    }

    /// What people type for a site: a bare host gets https://. Nil when it
    /// isn't a web address.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host?.isEmpty == false {
            return url.absoluteString
        }
        guard let url = URL(string: "https://" + trimmed), let host = url.host, host.contains(".") else { return nil }
        return url.absoluteString
    }

    /// A site as a slide's name: its host without "www.", and its path when
    /// it has one ("hopejc.org/events").
    public static func siteName(_ site: String) -> String {
        guard let url = URL(string: site), var host = url.host else { return site }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// Whether a slide shows the Browser: it goes up, so its window comes
    /// to the front for the operator to drive.
    public static func shows(_ slide: Slide) -> Bool {
        slide.objects.contains { $0.fill?.liveInputId == inputID }
    }
}
