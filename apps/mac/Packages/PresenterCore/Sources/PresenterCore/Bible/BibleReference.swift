import Foundation

public struct BibleBook: Hashable, Sendable {
    public var name: String
    /// USFM book code, as API.Bible passage ids use ("GEN", "1CO").
    public var code: String
    public var aliases: [String]
    public var chapterCount: Int

    /// Chapter bounds and a conservative verse ceiling, with exact ESV limits
    /// for single-chapter books (so, for example, Jude 1:30 is rejected).
    public func isValid(_ reference: BibleReference) -> Bool {
        guard reference.book == self, (1...chapterCount).contains(reference.chapter) else { return false }
        if let endChapter = reference.endChapter,
           !(reference.chapter...chapterCount).contains(endChapter) { return false }
        let verseLimit: Int
        switch code {
        case "OBA": verseLimit = 21
        case "PHM", "JUD": verseLimit = 25
        case "2JN": verseLimit = 13
        case "3JN": verseLimit = 15
        default: verseLimit = 176
        }
        for verse in [reference.startVerse, reference.endVerse].compactMap({ $0 }) {
            guard (1...verseLimit).contains(verse) else { return false }
        }
        if let start = reference.startVerse, let end = reference.endVerse,
           reference.endChapter ?? reference.chapter == reference.chapter, end < start { return false }
        return true
    }
}

/// A parsed passage: a book, a chapter, and an optional verse range that may
/// run into a later chapter ("John 3:16-4:2"). A nil `startVerse` means the
/// whole chapter.
public struct BibleReference: Hashable, Sendable {
    public var book: BibleBook
    public var chapter: Int
    public var startVerse: Int?
    public var endChapter: Int?
    public var endVerse: Int?

    public init(book: BibleBook, chapter: Int, startVerse: Int? = nil, endChapter: Int? = nil, endVerse: Int? = nil) {
        self.book = book
        self.chapter = chapter
        self.startVerse = startVerse
        self.endChapter = endChapter
        self.endVerse = endVerse
    }

    public var display: String {
        guard let startVerse else { return "\(book.name) \(chapter)" }
        var text = "\(book.name) \(chapter):\(startVerse)"
        if let endVerse {
            if let endChapter, endChapter != chapter {
                text += "–\(endChapter):\(endVerse)"
            } else if endVerse != startVerse {
                text += "–\(endVerse)"
            }
        }
        return text
    }

    /// API.Bible passage id: "JHN.3.16-JHN.3.18", or "JHN.3" for a chapter.
    public var apiBiblePassageID: String {
        guard let startVerse else { return "\(book.code).\(chapter)" }
        let start = "\(book.code).\(chapter).\(startVerse)"
        guard let endVerse else { return start }
        return "\(start)-\(book.code).\(endChapter ?? chapter).\(endVerse)"
    }

    /// Text query the ESV API accepts ("John 3:16-18").
    public var query: String {
        guard let startVerse else { return "\(book.name) \(chapter)" }
        var text = "\(book.name) \(chapter):\(startVerse)"
        if let endVerse {
            text += endChapter.map { "-\($0):\(endVerse)" } ?? "-\(endVerse)"
        }
        return text
    }

    /// Parses "Gen 32", "Genesis 32:1-5", "1 Cor 13:4–7", "John 3:16-4:2",
    /// "Ps 23 v 1". Returns nil when no book is recognized.
    public static func parse(_ input: String) -> BibleReference? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let bookRange = Range(match.range(at: 1), in: text),
              let chapterRange = Range(match.range(at: 2), in: text),
              let book = book(named: String(text[bookRange])),
              let chapter = Int(text[chapterRange])
        else { return nil }
        func int(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        let start = int(3)
        var endChapter: Int?
        var endVerse: Int?
        if let first = int(4) {
            if let second = int(5) {
                endChapter = first
                endVerse = second
            } else {
                endVerse = first
            }
        }
        if start == nil, let endVerse {
            // "Genesis 32-33" is a chapter range; keep it simple and read the first chapter.
            _ = endVerse
            return BibleReference(book: book, chapter: chapter)
        }
        return BibleReference(book: book, chapter: chapter, startVerse: start, endChapter: endChapter, endVerse: endVerse)
    }

    public static func book(named raw: String) -> BibleBook? {
        let key = normalize(raw)
        return lookup[key]
    }

    private static func normalize(_ raw: String) -> String {
        var name = raw.lowercased().replacingOccurrences(of: ".", with: "")
        for (roman, digit) in [("iii ", "3 "), ("ii ", "2 "), ("i ", "1 "), ("third ", "3 "), ("second ", "2 "), ("first ", "1 ")]
        where name.hasPrefix(roman) {
            name = digit + name.dropFirst(roman.count)
            break
        }
        return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: #"^([123]) ?"#, with: "$1 ", options: .regularExpression)
    }

    private static let lookup: [String: BibleBook] = {
        var table: [String: BibleBook] = [:]
        for book in books {
            for alias in [book.name] + book.aliases { table[normalize(alias)] = book }
        }
        return table
    }()

    static let pattern: NSRegularExpression = {
        let names = books.flatMap { [$0.name] + $0.aliases }
            .flatMap { name -> [String] in
                // Allow "1Cor", "I Cor", "First Corinthians" as well as "1 Cor".
                guard let digit = name.first, "123".contains(digit) else { return [name] }
                let rest = name.dropFirst().trimmingCharacters(in: .whitespaces)
                let roman = ["1": "I", "2": "II", "3": "III"][String(digit)]!
                let word = ["1": "First", "2": "Second", "3": "Third"][String(digit)]!
                return ["\(digit) \(rest)", "\(digit)\(rest)", "\(roman) \(rest)", "\(word) \(rest)"]
            }
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s*"#) }
            .joined(separator: "|")
        let verseSep = #"(?:\s*[:.]\s*|\s+v(?:v|s|erses?)?\.?\s*)"#
        return try! NSRegularExpression(
            pattern: #"\b(\#(names))\.?\s*(\d+)(?:\#(verseSep)(\d+)[a-c]?)?(?:\s*-\s*(\d+)(?:\s*:\s*(\d+))?[a-c]?)?(?![\w:]|[.-]\d)"#,
            options: [.caseInsensitive])
    }()

    public static let books: [BibleBook] = [
        .init(name: "Genesis", code: "GEN", aliases: ["Gen", "Gn"], chapterCount: 50),
        .init(name: "Exodus", code: "EXO", aliases: ["Exod", "Ex"], chapterCount: 40),
        .init(name: "Leviticus", code: "LEV", aliases: ["Lev", "Lv"], chapterCount: 27),
        .init(name: "Numbers", code: "NUM", aliases: ["Num", "Nm"], chapterCount: 36),
        .init(name: "Deuteronomy", code: "DEU", aliases: ["Deut", "Dt"], chapterCount: 34),
        .init(name: "Joshua", code: "JOS", aliases: ["Josh"], chapterCount: 24),
        .init(name: "Judges", code: "JDG", aliases: ["Judg", "Jdg"], chapterCount: 21),
        .init(name: "Ruth", code: "RUT", aliases: ["Rth"], chapterCount: 4),
        .init(name: "1 Samuel", code: "1SA", aliases: ["1 Sam", "1 Sm"], chapterCount: 31),
        .init(name: "2 Samuel", code: "2SA", aliases: ["2 Sam", "2 Sm"], chapterCount: 24),
        .init(name: "1 Kings", code: "1KI", aliases: ["1 Kgs", "1 Kin"], chapterCount: 22),
        .init(name: "2 Kings", code: "2KI", aliases: ["2 Kgs", "2 Kin"], chapterCount: 25),
        .init(name: "1 Chronicles", code: "1CH", aliases: ["1 Chron", "1 Chr"], chapterCount: 29),
        .init(name: "2 Chronicles", code: "2CH", aliases: ["2 Chron", "2 Chr"], chapterCount: 36),
        .init(name: "Ezra", code: "EZR", aliases: ["Ezr"], chapterCount: 10),
        .init(name: "Nehemiah", code: "NEH", aliases: ["Neh"], chapterCount: 13),
        .init(name: "Esther", code: "EST", aliases: ["Esth", "Est"], chapterCount: 10),
        .init(name: "Job", code: "JOB", aliases: ["Jb"], chapterCount: 42),
        .init(name: "Psalms", code: "PSA", aliases: ["Psalm", "Ps", "Pss", "Psa"], chapterCount: 150),
        .init(name: "Proverbs", code: "PRO", aliases: ["Prov", "Prv", "Pr"], chapterCount: 31),
        .init(name: "Ecclesiastes", code: "ECC", aliases: ["Eccl", "Eccles", "Ecc"], chapterCount: 12),
        .init(name: "Song of Songs", code: "SNG", aliases: ["Song of Solomon", "Song", "SoS"], chapterCount: 8),
        .init(name: "Isaiah", code: "ISA", aliases: ["Isa", "Is"], chapterCount: 66),
        .init(name: "Jeremiah", code: "JER", aliases: ["Jer"], chapterCount: 52),
        .init(name: "Lamentations", code: "LAM", aliases: ["Lam"], chapterCount: 5),
        .init(name: "Ezekiel", code: "EZK", aliases: ["Ezek", "Eze"], chapterCount: 48),
        .init(name: "Daniel", code: "DAN", aliases: ["Dan", "Dn"], chapterCount: 12),
        .init(name: "Hosea", code: "HOS", aliases: ["Hos"], chapterCount: 14),
        .init(name: "Joel", code: "JOL", aliases: ["Jl"], chapterCount: 3),
        .init(name: "Amos", code: "AMO", aliases: ["Am"], chapterCount: 9),
        .init(name: "Obadiah", code: "OBA", aliases: ["Obad", "Ob"], chapterCount: 1),
        .init(name: "Jonah", code: "JON", aliases: ["Jon"], chapterCount: 4),
        .init(name: "Micah", code: "MIC", aliases: ["Mic"], chapterCount: 7),
        .init(name: "Nahum", code: "NAM", aliases: ["Nah"], chapterCount: 3),
        .init(name: "Habakkuk", code: "HAB", aliases: ["Hab"], chapterCount: 3),
        .init(name: "Zephaniah", code: "ZEP", aliases: ["Zeph"], chapterCount: 3),
        .init(name: "Haggai", code: "HAG", aliases: ["Hag"], chapterCount: 2),
        .init(name: "Zechariah", code: "ZEC", aliases: ["Zech"], chapterCount: 14),
        .init(name: "Malachi", code: "MAL", aliases: ["Mal"], chapterCount: 4),
        .init(name: "Matthew", code: "MAT", aliases: ["Matt", "Mt"], chapterCount: 28),
        .init(name: "Mark", code: "MRK", aliases: ["Mk", "Mrk"], chapterCount: 16),
        .init(name: "Luke", code: "LUK", aliases: ["Lk"], chapterCount: 24),
        .init(name: "John", code: "JHN", aliases: ["Jn", "Jhn"], chapterCount: 21),
        .init(name: "Acts", code: "ACT", aliases: ["Act"], chapterCount: 28),
        .init(name: "Romans", code: "ROM", aliases: ["Rom", "Rm"], chapterCount: 16),
        .init(name: "1 Corinthians", code: "1CO", aliases: ["1 Cor", "1 Co"], chapterCount: 16),
        .init(name: "2 Corinthians", code: "2CO", aliases: ["2 Cor", "2 Co"], chapterCount: 13),
        .init(name: "Galatians", code: "GAL", aliases: ["Gal"], chapterCount: 6),
        .init(name: "Ephesians", code: "EPH", aliases: ["Eph"], chapterCount: 6),
        .init(name: "Philippians", code: "PHP", aliases: ["Phil", "Php"], chapterCount: 4),
        .init(name: "Colossians", code: "COL", aliases: ["Col"], chapterCount: 4),
        .init(name: "1 Thessalonians", code: "1TH", aliases: ["1 Thess", "1 Th"], chapterCount: 5),
        .init(name: "2 Thessalonians", code: "2TH", aliases: ["2 Thess", "2 Th"], chapterCount: 3),
        .init(name: "1 Timothy", code: "1TI", aliases: ["1 Tim", "1 Ti"], chapterCount: 6),
        .init(name: "2 Timothy", code: "2TI", aliases: ["2 Tim", "2 Ti"], chapterCount: 4),
        .init(name: "Titus", code: "TIT", aliases: ["Tit"], chapterCount: 3),
        .init(name: "Philemon", code: "PHM", aliases: ["Phlm", "Philem"], chapterCount: 1),
        .init(name: "Hebrews", code: "HEB", aliases: ["Heb"], chapterCount: 13),
        .init(name: "James", code: "JAS", aliases: ["Jas", "Jms"], chapterCount: 5),
        .init(name: "1 Peter", code: "1PE", aliases: ["1 Pet", "1 Pt"], chapterCount: 5),
        .init(name: "2 Peter", code: "2PE", aliases: ["2 Pet", "2 Pt"], chapterCount: 3),
        .init(name: "1 John", code: "1JN", aliases: ["1 Jn", "1 Jhn"], chapterCount: 5),
        .init(name: "2 John", code: "2JN", aliases: ["2 Jn", "2 Jhn"], chapterCount: 1),
        .init(name: "3 John", code: "3JN", aliases: ["3 Jn", "3 Jhn"], chapterCount: 1),
        .init(name: "Jude", code: "JUD", aliases: ["Jud"], chapterCount: 1),
        .init(name: "Revelation", code: "REV", aliases: ["Rev", "Revelations", "Rv"], chapterCount: 22),
    ]
}
