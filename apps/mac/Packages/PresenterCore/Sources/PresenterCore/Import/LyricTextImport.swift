import Foundation

public enum LyricTextFormat: String, Sendable, Equatable {
    case songSelect
    case chordPro
    case plainText
}

public enum LyricTextImporter {

    public struct Normalized: Equatable {
        public var format: LyricTextFormat
        public var title: String?
        public var ccli: CCLIInfo?
        public var chordProSource: String?

        public var musicKey: String?

        public var body: String
    }

    /// A lyrics file's text: UTF-8, UTF-16 with its byte-order mark, else
    /// Latin-1. Nil for binary data (any NUL byte outside UTF-16), which
    /// Latin-1 would otherwise decode into a song of junk.
    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    public static func detectFormat(_ text: String) -> LyricTextFormat {
        var directiveHits = 0
        var chordLineHits = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if chordProDirectiveRegex.wholeMatch(trimmed) { directiveHits += 1 }
            if inlineChordRegex.firstMatch(in: trimmed) != nil { chordLineHits += 1 }
        }
        // A directive settles it before the CCLI footer does: ChordPro files
        // often carry the licence footer too, and read as SongSelect text
        // their {title} and {key} lines would reach the slides.
        if directiveHits >= 1 { return .chordPro }
        if ccliSongNumberRegex.firstMatch(in: text) != nil { return .songSelect }
        if chordLineHits >= 2 { return .chordPro }
        return .plainText
    }

    public static func makePresentation(
        _ text: String,
        fallbackTitle: String? = nil,
        id: String = UUID().uuidString,
        folder: String? = nil,
        themeId: String = "",
        linesPerSlide: Int = 2
    ) -> Presentation {
        let normalized = normalize(text)
        let built = Reflow.build(
            Reflow.parse(normalized.body, linesPerSlide: linesPerSlide).openingOnBlank()
        )
        var slides = built.slides
        if slides.isEmpty {
            slides = [Slide(id: UUID().uuidString, name: "", objects: [])]
        }
        return Presentation(
            id: id,
            name: normalized.title ?? fallbackTitle ?? "Imported Lyrics",
            presentationKind: .deck,
            themeId: themeId,
            folder: folder,
            slides: slides,
            sections: built.sections.isEmpty ? nil : built.sections,
            arrangements: built.arrangement.map { [$0] },
            defaultArrangementId: built.arrangement?.id,
            reflowSource: normalized.body.isEmpty ? nil : normalized.body,
            ccli: normalized.ccli,
            chordProSource: normalized.chordProSource,
            musicKey: normalized.musicKey
        )
    }

    public static func normalize(_ text: String) -> Normalized {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch detectFormat(unified) {
        case .songSelect: return normalizeSongSelect(unified)
        case .chordPro: return normalizeChordPro(unified)
        case .plainText:
            return Normalized(format: .plainText, body: unified.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Takes the "CCLI Song #" footer (number, authors, © lines and the
    /// licence lines after them) off the end of `lines`.
    private static func takeCCLIFooter(_ lines: inout [String]) -> CCLIInfo? {
        guard let footerStart = lines.firstIndex(where: {
            chordProDirective(from: $0.trimmingCharacters(in: .whitespaces)) == nil
                && ccliSongNumberRegex.firstMatch(in: $0) != nil
        }) else { return nil }
        let footer = lines[footerStart...].map { $0.trimmingCharacters(in: .whitespaces) }
        // A ChordPro song that goes on after the line (directives, chords)
        // has it as a heading, not a footer; the song isn't cut there.
        guard !footer.contains(where: {
            chordProDirective(from: $0) != nil || inlineChordRegex.firstMatch(in: $0) != nil
        }) else { return nil }
        var ccli = CCLIInfo()
        lines = Array(lines[..<footerStart])
        for (offset, line) in footer.enumerated() {
            if let number = ccliSongNumberRegex.firstMatch(in: line) {
                ccli.songNumber = Int(number)

                let next = footer.dropFirst(offset + 1).first(where: { !$0.isEmpty })
                if let authors = next, !authors.hasPrefix("©"), !isCCLIBoilerplate(authors) {
                    ccli.author = authors
                }
            } else if line.hasPrefix("©") {
                ccli.copyright = (ccli.copyright.map { $0 + "\n" } ?? "") + line
                if ccli.copyrightYear == nil {
                    ccli.copyrightYear = copyrightYearRegex.firstMatch(in: line).flatMap { Int($0) }
                }
            }
        }
        return ccli
    }

    private static func normalizeSongSelect(_ text: String) -> Normalized {
        var lines = text.components(separatedBy: "\n")
        var ccli = takeCCLIFooter(&lines) ?? CCLIInfo()

        var title: String?
        var body: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if title == nil {
                if !line.isEmpty { title = line }
                continue
            }
            body.append(line)
        }
        ccli.songTitle = title

        return Normalized(
            format: .songSelect,
            title: title,
            ccli: ccli == CCLIInfo(songTitle: title) && title == nil ? nil : ccli,
            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func normalizeChordPro(_ text: String) -> Normalized {
        var title: String?
        var ccli = CCLIInfo()
        var hasCCLI = false
        var musicKey: String?
        var body: [String] = []
        // Inside a tab, grid or notation block nothing is sung, so none of
        // it may reach a slide.
        var skippingUntil: String?
        var lastChorus = "Chorus"

        func appendLabel(_ label: String) {
            if body.last?.isEmpty == false { body.append("") }
            body.append(label)
        }

        /// A section's name: its label when we know it as a section name,
        /// otherwise the kind of section it opens.
        func sectionLabel(_ value: String?, fallback: String) -> String {
            guard let value, let label = Reflow.labelName(of: value) else { return fallback }
            return label
        }

        // A licence footer after the song is read for its CCLI details and
        // kept off the last slide.
        var lines = text.components(separatedBy: "\n")
        let footer = takeCCLIFooter(&lines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let directive = chordProDirective(from: line) {
                if let end = skippingUntil {
                    if directive.key == end { skippingUntil = nil }
                    continue
                }
                switch directive.key {
                case "title", "t":
                    if title == nil { title = directive.value }
                case "subtitle", "st", "artist", "author":
                    if ccli.author == nil, let value = directive.value {
                        ccli.author = value
                        hasCCLI = true
                    }
                case "copyright":
                    if let value = directive.value {
                        ccli.copyright = value
                        ccli.copyrightYear = copyrightYearRegex.firstMatch(in: value).flatMap { Int($0) }
                        hasCCLI = true
                    }
                case "ccli":
                    if let value = directive.value, let number = Int(value.filter(\.isNumber)), number > 0 {
                        ccli.songNumber = number
                        hasCCLI = true
                    }
                case "comment", "c", "comment_italic", "ci", "comment_box", "cb", "highlight":
                    // Only a comment that names a section starts one; "Repeat
                    // x2" and the like are notes for the band.
                    if let value = directive.value, let label = Reflow.labelName(of: value) {
                        if label.hasPrefix("Chorus") { lastChorus = label }
                        appendLabel(label)
                    } else if ccli.songNumber == nil, let value = directive.value,
                              let number = ccliSongNumberRegex.firstMatch(in: value).flatMap({ Int($0) }) {
                        ccli.songNumber = number
                        hasCCLI = true
                    }
                case "start_of_chorus", "soc":
                    lastChorus = sectionLabel(directive.value, fallback: "Chorus")
                    appendLabel(lastChorus)
                case "chorus":
                    // "Sing the chorus again": the label alone repeats it.
                    appendLabel(directive.value.flatMap { Reflow.labelName(of: $0) } ?? lastChorus)
                case "start_of_verse", "sov":
                    appendLabel(sectionLabel(directive.value, fallback: "Verse"))
                case "start_of_bridge", "sob":
                    appendLabel(sectionLabel(directive.value, fallback: "Bridge"))
                case "start_of_tab", "sot", "start_of_grid", "sog", "start_of_abc", "start_of_ly",
                     "start_of_svg", "start_of_textblock":
                    skippingUntil = Self.endDirective(for: directive.key)
                case "key":
                    // The song's first key; a later {key} is a key change.
                    if musicKey == nil, let value = directive.value, ChordMath.parseKey(value) != nil {
                        musicKey = value
                    }
                default:
                    // Any other start_of_ is a section of its own kind
                    // ({start_of_intro}, {start_of_tag: Tag 2}).
                    if directive.key.hasPrefix("start_of_") {
                        let kind = String(directive.key.dropFirst("start_of_".count))
                        if let label = directive.value.flatMap({ Reflow.labelName(of: $0) })
                            ?? Reflow.labelName(of: kind.replacingOccurrences(of: "_", with: " ")) {
                            appendLabel(label)
                        }
                    }
                }
                continue
            }
            if skippingUntil != nil { continue }
            // ChordPro comments.
            if line.hasPrefix("#") { continue }
            if line.isEmpty {
                if body.last?.isEmpty == false { body.append("") }
                continue
            }
            body.append(line)
        }
        if let footer {
            ccli.songNumber = ccli.songNumber ?? footer.songNumber
            ccli.author = ccli.author ?? footer.author
            if ccli.copyright == nil {
                ccli.copyright = footer.copyright
                ccli.copyrightYear = footer.copyrightYear
            }
            hasCCLI = true
        }

        return Normalized(
            format: .chordPro,
            title: title,
            ccli: hasCCLI ? ccli : nil,
            chordProSource: text,
            musicKey: musicKey,
            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func endDirective(for start: String) -> String {
        switch start {
        case "sot": return "eot"
        case "sog": return "eog"
        default: return "end_of_" + start.dropFirst("start_of_".count)
        }
    }

    /// `{key: value}`, `{key value}` and ChordPro 6's `{key label="value"}`.
    /// Instrument selectors (`{title-guitar: …}`) are read as the plain key.
    private static func chordProDirective(from line: String) -> (key: String, value: String?)? {
        guard line.hasPrefix("{"), line.hasSuffix("}") else { return nil }
        let body = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let keyEnd = body.firstIndex(where: { $0 == ":" || $0.isWhitespace }) ?? body.endIndex
        var key = body[..<keyEnd].lowercased()
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) else { return nil }
        if let dash = key.firstIndex(of: "-") { key = String(key[..<dash]) }
        var value = body[keyEnd...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(":") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let label = chordProLabelAttribute.firstMatch(in: value) { value = label }
        return (key, value.isEmpty ? nil : value)
    }

    private static func isCCLIBoilerplate(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("songselect")
            || line.localizedCaseInsensitiveContains("ccli licen")
            || line.localizedCaseInsensitiveContains("all rights reserved")
            || line.localizedCaseInsensitiveContains("www.ccli.com")
    }

    private static let ccliSongNumberRegex = SimpleRegex(#"CCLI Song #\s*(\d+)"#, caseInsensitive: true)
    private static let copyrightYearRegex = SimpleRegex(#"(\b(?:19|20)\d{2}\b)"#)
    private static let chordProDirectiveRegex = SimpleRegex(#"^\{[a-zA-Z_]+(-[a-zA-Z]+)?([:\s].*)?\}$"#)
    private static let chordProLabelAttribute = SimpleRegex(#"^label\s*=\s*["']([^"']*)["']"#)
    private static let inlineChordRegex = SimpleRegex(#"\[[A-G][#b]?(?:m|maj|min|dim|aug|sus|add)?\d*(?:/[A-G][#b]?)?\]"#)
}

struct SimpleRegex {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func firstMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let groupRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let swiftRange = Range(groupRange.location == NSNotFound ? match.range : groupRange, in: text) else { return nil }
        return String(text[swiftRange])
    }

    func wholeMatch(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range == range
    }
}
