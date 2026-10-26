import Foundation

/// What a slide tile says under its picture, so whoever runs the show can
/// tell at a glance what each slide is: the passage on a scripture slide,
/// the group on a song, the point on a message slide, the file on a media
/// slide. The slide's number is the tile's own; it isn't part of this.
public struct SlideLabel: Equatable, Sendable {
    /// The main line, drawn large.
    public var title: String
    /// Smaller text with it: the translation, which point, a lyric's first
    /// line, a video's length.
    public var detail: String?
    /// The title is a scripture reference, so a tile too narrow for it cuts
    /// the middle and keeps the book and the last verse.
    public var isReference: Bool

    public init(title: String, detail: String? = nil, isReference: Bool = false) {
        self.title = title
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.isReference = isReference
    }
}

public enum SlideLabels {

    /// The label for a slide at `index` (its place in the arranged order) of
    /// `presentation`. `mediaName` is the name of the slide's background
    /// media, when it has one, for a slide that is only a picture or video.
    public static func label(
        for slide: Slide, at index: Int, in presentation: Presentation, mediaName: String? = nil
    ) -> SlideLabel {
        if let scripture = scriptureLabel(slide, in: presentation) { return scripture }
        if let message = messageLabel(slide, in: presentation) { return message }

        let text = firstLine(of: slide)
        let ownName = meaningfulName(slide, mediaName: mediaName, hasText: !text.isEmpty)
        let group = sectionName(slide, in: presentation)

        // A song's slides are its groups; a slide's own name, where a deck
        // gives one, says more than the group it sits in.
        if presentation.presentationKind == .song, let group {
            return SlideLabel(title: group, detail: text)
        }
        if let ownName { return SlideLabel(title: ownName) }
        if let group { return SlideLabel(title: group, detail: text) }
        if !text.isEmpty { return SlideLabel(title: text) }
        if slide.background != nil, let mediaName = trimmed(mediaName) { return SlideLabel(title: mediaName) }
        if !slide.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return SlideLabel(title: slide.name.trimmingCharacters(in: .whitespaces))
        }
        return SlideLabel(title: "Slide \(index + 1)")
    }

    /// A media item in a plan: the countdown says so, with its length, and
    /// any other video or picture gives its name.
    public static func mediaItem(name: String, isCountdown: Bool, durationSeconds: Double?) -> SlideLabel {
        let length = durationSeconds.flatMap { $0 > 0 ? timecode($0) : nil }
        if isCountdown {
            let title = length.map { "Countdown \($0)" } ?? "Countdown"
            let shown = ServiceCountdown.looksLikeCountdown(name) ? nil : trimmed(name)
            return SlideLabel(title: title, detail: shown)
        }
        return SlideLabel(title: trimmed(name) ?? "Media", detail: length)
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Scripture

    /// The design scripture is laid out by, in a Bible presentation and in
    /// a message's series theme alike.
    static let scriptureDesign = SermonSeriesTheme.scriptureCategory

    static func isScripture(_ slide: Slide, in presentation: Presentation) -> Bool {
        slide.themeSlideName == scriptureDesign
            || PresentationTypes.category(of: presentation) == PresentationTypes.bible
    }

    /// The passage on this slide. Scripture slides are named for their
    /// verses when they're made ("Genesis 32:3–5"); a slide without that
    /// name is read from its verse numbers against the passage the deck is
    /// for, counting chapters on where the numbers start again.
    static func scriptureLabel(_ slide: Slide, in presentation: Presentation) -> SlideLabel? {
        guard isScripture(slide, in: presentation) else { return nil }
        let translation = translation(in: objectText(slide, named: "Reference"))
            ?? translation(in: slide.name)
            ?? translation(in: presentation.name)
        let named = BibleReference.parse(slide.name)
        if let named, named.startVerse != nil {
            return SlideLabel(title: named.display, detail: translation, isReference: true)
        }
        if let derived = derivedReference(slide, in: presentation) {
            return SlideLabel(title: derived, detail: translation, isReference: true)
        }
        if let named {
            return SlideLabel(title: named.display, detail: translation, isReference: true)
        }
        return nil
    }

    /// "ESV" from "Genesis 32:3–5 ESV" or "Genesis 32 (ESV)".
    static func translation(in text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let lastLine = text.components(separatedBy: .newlines).last ?? text
        if let match = lastLine.firstMatch(of: /\(([A-Z][A-Z0-9]{1,7})\)\s*$/) { return String(match.1) }
        if let match = lastLine.firstMatch(of: /\d\s+([A-Z][A-Z0-9]{1,7})\s*$/) { return String(match.1) }
        return nil
    }

    private static func derivedReference(_ slide: Slide, in presentation: Presentation) -> String? {
        let base = [objectText(slide, named: "Reference"), presentation.name]
            .compactMap { $0 }
            .lazy.compactMap { BibleReference.parse($0) }
            .first
        guard let base else { return nil }

        // Walk the deck's scripture slides in their own order up to this
        // one: a verse number lower than the last means the next chapter.
        var chapter = base.chapter
        var lastVerse: Int?
        for candidate in presentation.slides where isScripture(candidate, in: presentation) {
            let text = verseText(candidate)
            var numbered = verseNumbers(in: text)
            var verses: [BibleVerse] = []
            // A page that opens mid-verse carries on the last one.
            if let lastVerse, !startsWithVerseNumber(text) {
                verses.append(BibleVerse(chapter: chapter, verse: lastVerse, text: ""))
            }
            if numbered.isEmpty, verses.isEmpty, candidate.id == slide.id {
                return base.display
            }
            while !numbered.isEmpty {
                let verse = numbered.removeFirst()
                if let previous = lastVerse, verse < previous { chapter += 1 }
                verses.append(BibleVerse(chapter: chapter, verse: verse, text: ""))
                lastVerse = verse
            }
            if candidate.id == slide.id {
                return verses.isEmpty
                    ? base.display
                    : ScripturePage(text: "", verses: verses, continuesVerse: false).reference(book: base.book)
            }
        }
        return base.display
    }

    private static let superscriptDigits: [Character: Int] = [
        "⁰": 0, "¹": 1, "²": 2, "³": 3, "⁴": 4, "⁵": 5, "⁶": 6, "⁷": 7, "⁸": 8, "⁹": 9,
    ]

    /// The verse numbers ScriptureText.render puts before each verse.
    static func verseNumbers(in text: String) -> [Int] {
        var numbers: [Int] = []
        var current: Int?
        for character in text {
            if let digit = superscriptDigits[character] {
                current = (current ?? 0) * 10 + digit
            } else if let number = current {
                numbers.append(number)
                current = nil
            }
        }
        if let current { numbers.append(current) }
        return numbers
    }

    private static func startsWithVerseNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).first.map { superscriptDigits[$0] != nil } ?? false
    }

    /// The verses' own text box, or every text box when there's no box
    /// named for them.
    private static func verseText(_ slide: Slide) -> String {
        objectText(slide, named: "Verse")
            ?? slide.objects.filter { $0.objectKind == .text }.map(\.text).joined(separator: "\n")
    }

    // MARK: Message notes

    /// The message's designs: a title, points, and points with a verse.
    /// Each point is counted through the message, so "Point 2" is the
    /// second point however many title or scripture slides sit between.
    static func messageLabel(_ slide: Slide, in presentation: Presentation) -> SlideLabel? {
        switch slide.themeSlideName {
        case SermonSeriesTheme.titleCategory:
            let title = trimmed(slide.name) ?? trimmed(objectText(slide, named: "Title"))
            return SlideLabel(title: title ?? "Title", detail: title == nil ? nil : "Title")
        case SermonSeriesTheme.pointCategory, SermonSeriesTheme.pointScriptureCategory:
            let pointDesigns: Set<String> = [SermonSeriesTheme.pointCategory, SermonSeriesTheme.pointScriptureCategory]
            let points = presentation.slides.filter { pointDesigns.contains($0.themeSlideName ?? "") }
            let number = (points.firstIndex { $0.id == slide.id } ?? 0) + 1
            let point = "Point \(number)"
            let title = trimmed(slide.name) ?? trimmed(objectText(slide, named: "Point"))
            var detail = title == nil ? nil : point
            if slide.themeSlideName == SermonSeriesTheme.pointScriptureCategory,
               let reference = trimmed(objectText(slide, named: "Reference")) {
                detail = [detail, reference].compactMap { $0 }.joined(separator: " · ")
            }
            return SlideLabel(title: title ?? point, detail: detail)
        default:
            return nil
        }
    }

    // MARK: Everything else

    private static func sectionName(_ slide: Slide, in presentation: Presentation) -> String? {
        guard let id = slide.sectionId, !id.isEmpty else { return nil }
        return trimmed(presentation.sections?.first { $0.id == id }?.name)
    }

    /// The slide's own name, unless it only repeats the background's file
    /// name over slide text that says more.
    private static func meaningfulName(_ slide: Slide, mediaName: String?, hasText: Bool) -> String? {
        guard let name = trimmed(slide.name) else { return nil }
        if hasText, let mediaName = trimmed(mediaName), sameFile(name, mediaName) { return nil }
        return name
    }

    private static func sameFile(_ name: String, _ mediaName: String) -> Bool {
        let strip: (String) -> String = { ($0 as NSString).deletingPathExtension.lowercased() }
        return name.lowercased() == mediaName.lowercased() || strip(name) == strip(mediaName)
    }

    /// The first line of the slide's text, with verse numbers and extra
    /// spacing taken out.
    static func firstLine(of slide: Slide) -> String {
        slide.objects
            .filter { $0.objectKind == .text }
            .flatMap { $0.text.components(separatedBy: .newlines) }
            .lazy
            .map { line in
                String(line.filter { superscriptDigits[$0] == nil && $0 != "\u{2009}" })
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .first { !$0.isEmpty } ?? ""
    }

    private static func objectText(_ slide: Slide, named name: String) -> String? {
        slide.objects.first { $0.objectKind == .text && $0.name == name && !$0.text.isEmpty }?.text
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
