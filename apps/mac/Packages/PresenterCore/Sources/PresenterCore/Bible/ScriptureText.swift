import Foundation

public struct BibleVerse: Hashable, Sendable {
    public var chapter: Int
    public var verse: Int
    public var text: String

    public init(chapter: Int, verse: Int, text: String) {
        self.chapter = chapter
        self.verse = verse
        self.text = text
    }
}

public struct ScriptureFormat: Hashable, Sendable {
    /// Off by default: a passage reads as straight text from top to bottom.
    public var keepsLineBreaks = false
    public var showsVerseNumbers = true

    public init(keepsLineBreaks: Bool = false, showsVerseNumbers: Bool = true) {
        self.keepsLineBreaks = keepsLineBreaks
        self.showsVerseNumbers = showsVerseNumbers
    }
}

public enum ScriptureText {

    /// Splits provider text marked "[16] For God… [17] For God did not…" into
    /// verses. A "[4:1]" marker moves to a new chapter; text before the first
    /// marker belongs to `startVerse`.
    public static func verses(fromMarked text: String, chapter: Int, startVerse: Int) -> [BibleVerse] {
        let regex = try! NSRegularExpression(pattern: #"\[(?:(\d+):)?(\d+)\]"#)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var verses: [BibleVerse] = []
        var currentChapter = chapter
        var lastVerse = startVerse - 1

        let leading = ns.substring(to: matches.first?.range.location ?? ns.length)
        if !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            verses.append(BibleVerse(chapter: chapter, verse: startVerse, text: leading))
            lastVerse = startVerse
        }
        for (index, match) in matches.enumerated() {
            let number = Int(ns.substring(with: match.range(at: 2))) ?? lastVerse + 1
            if match.range(at: 1).location != NSNotFound {
                currentChapter = Int(ns.substring(with: match.range(at: 1))) ?? currentChapter
            } else if number < lastVerse {
                currentChapter += 1
            }
            lastVerse = number
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            verses.append(BibleVerse(chapter: currentChapter, verse: number, text: body))
        }
        return verses
    }

    /// Removes line breaks and extra spacing by default, so poetry and
    /// paragraph breaks don't leave ragged slides. With `keepsLineBreaks` the
    /// breaks stay, but blank lines and stray indentation are still tidied.
    public static func clean(_ text: String, keepsLineBreaks: Bool) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines.joined(separator: keepsLineBreaks ? "\n" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func superscript(_ number: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        ]
        return String(String(number).map { digits[$0] ?? $0 })
    }

    public static func render(_ verse: BibleVerse, format: ScriptureFormat) -> String {
        let body = clean(verse.text, keepsLineBreaks: format.keepsLineBreaks)
        return format.showsVerseNumbers ? "\(superscript(verse.verse))\u{2009}\(body)" : body
    }
}

public extension BiblePassage {
    /// The whole passage by its first and last verse ("Genesis 28:1–22"),
    /// even when it was asked for as a chapter.
    var versesReference: String {
        ScripturePage(text: "", verses: verses, continuesVerse: false).reference(book: reference.book)
    }
}

/// One slide's worth of scripture.
public struct ScripturePage: Hashable, Sendable {
    public var text: String
    public var verses: [BibleVerse]
    /// True when this page continues a verse too long to fit on one slide.
    public var continuesVerse: Bool

    public func reference(book: BibleBook) -> String {
        guard let first = verses.first, let last = verses.last else { return book.name }
        var text = "\(book.name) \(first.chapter):\(first.verse)"
        if last.chapter != first.chapter {
            text += "–\(last.chapter):\(last.verse)"
        } else if last.verse != first.verse {
            text += "–\(last.verse)"
        }
        return text
    }
}

public enum ScripturePaginator {

    /// Packs whole verses onto slides. When the next verse doesn't fit, the
    /// slide ends and the next one starts at the beginning of that verse, so
    /// no slide ever opens mid-verse. A single verse too long for any slide is
    /// the one exception: it continues across slides at a word boundary.
    public static func paginate(
        _ verses: [BibleVerse], format: ScriptureFormat, fits: (String) -> Bool
    ) -> [ScripturePage] {
        let separator = format.keepsLineBreaks ? "\n" : " "
        var pages: [ScripturePage] = []
        var current: [BibleVerse] = []
        var currentText = ""

        func flush() {
            if !current.isEmpty {
                pages.append(ScripturePage(text: currentText, verses: current, continuesVerse: false))
            }
            current = []
            currentText = ""
        }

        for verse in verses {
            let rendered = ScriptureText.render(verse, format: format)
            let candidate = currentText.isEmpty ? rendered : currentText + separator + rendered
            if fits(candidate) {
                current.append(verse)
                currentText = candidate
                continue
            }
            flush()
            if fits(rendered) {
                current = [verse]
                currentText = rendered
            } else {
                pages += split(oversized: verse, rendered: rendered, fits: fits)
            }
        }
        flush()
        return pages
    }

    private static func split(oversized verse: BibleVerse, rendered: String, fits: (String) -> Bool) -> [ScripturePage] {
        var pages: [ScripturePage] = []
        var words = rendered.split(separator: " ").map(String.init)
        while !words.isEmpty {
            var take = 1
            while take < words.count, fits(words[0...take].joined(separator: " ")) { take += 1 }
            pages.append(ScripturePage(
                text: words[0..<take].joined(separator: " "), verses: [verse], continuesVerse: !pages.isEmpty))
            words.removeFirst(take)
        }
        return pages
    }
}
