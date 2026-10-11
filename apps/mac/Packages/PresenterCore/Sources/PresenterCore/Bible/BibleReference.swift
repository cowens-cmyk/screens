import Foundation

public struct BibleBook: Hashable, Sendable {
    public var name: String
    /// USFM book code, as API.Bible passage ids use ("GEN", "1CO").
    public var code: String
    public var aliases: [String]
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

    private static let pattern: NSRegularExpression = {
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
            pattern: #"\b(\#(names))\.?\s*(\d+)(?:\#(verseSep)(\d+)[a-c]?)?(?:\s*-\s*(\d+)(?:\s*:\s*(\d+))?[a-c]?)?"#,
            options: [.caseInsensitive])
    }()

    public static let books: [BibleBook] = [
        .init(name: "Genesis", code: "GEN", aliases: ["Gen", "Gn"]),
        .init(name: "Exodus", code: "EXO", aliases: ["Exod", "Ex"]),
        .init(name: "Leviticus", code: "LEV", aliases: ["Lev", "Lv"]),
        .init(name: "Numbers", code: "NUM", aliases: ["Num", "Nm"]),
        .init(name: "Deuteronomy", code: "DEU", aliases: ["Deut", "Dt"]),
        .init(name: "Joshua", code: "JOS", aliases: ["Josh"]),
        .init(name: "Judges", code: "JDG", aliases: ["Judg", "Jdg"]),
        .init(name: "Ruth", code: "RUT", aliases: ["Rth"]),
        .init(name: "1 Samuel", code: "1SA", aliases: ["1 Sam", "1 Sm"]),
        .init(name: "2 Samuel", code: "2SA", aliases: ["2 Sam", "2 Sm"]),
        .init(name: "1 Kings", code: "1KI", aliases: ["1 Kgs", "1 Kin"]),
        .init(name: "2 Kings", code: "2KI", aliases: ["2 Kgs", "2 Kin"]),
        .init(name: "1 Chronicles", code: "1CH", aliases: ["1 Chron", "1 Chr"]),
        .init(name: "2 Chronicles", code: "2CH", aliases: ["2 Chron", "2 Chr"]),
        .init(name: "Ezra", code: "EZR", aliases: ["Ezr"]),
        .init(name: "Nehemiah", code: "NEH", aliases: ["Neh"]),
        .init(name: "Esther", code: "EST", aliases: ["Esth", "Est"]),
        .init(name: "Job", code: "JOB", aliases: ["Jb"]),
        .init(name: "Psalms", code: "PSA", aliases: ["Psalm", "Ps", "Pss", "Psa"]),
        .init(name: "Proverbs", code: "PRO", aliases: ["Prov", "Prv", "Pr"]),
        .init(name: "Ecclesiastes", code: "ECC", aliases: ["Eccl", "Eccles", "Ecc"]),
        .init(name: "Song of Songs", code: "SNG", aliases: ["Song of Solomon", "Song", "SoS"]),
        .init(name: "Isaiah", code: "ISA", aliases: ["Isa", "Is"]),
        .init(name: "Jeremiah", code: "JER", aliases: ["Jer"]),
        .init(name: "Lamentations", code: "LAM", aliases: ["Lam"]),
        .init(name: "Ezekiel", code: "EZK", aliases: ["Ezek", "Eze"]),
        .init(name: "Daniel", code: "DAN", aliases: ["Dan", "Dn"]),
        .init(name: "Hosea", code: "HOS", aliases: ["Hos"]),
        .init(name: "Joel", code: "JOL", aliases: ["Jl"]),
        .init(name: "Amos", code: "AMO", aliases: ["Am"]),
        .init(name: "Obadiah", code: "OBA", aliases: ["Obad", "Ob"]),
        .init(name: "Jonah", code: "JON", aliases: ["Jon"]),
        .init(name: "Micah", code: "MIC", aliases: ["Mic"]),
        .init(name: "Nahum", code: "NAM", aliases: ["Nah"]),
        .init(name: "Habakkuk", code: "HAB", aliases: ["Hab"]),
        .init(name: "Zephaniah", code: "ZEP", aliases: ["Zeph"]),
        .init(name: "Haggai", code: "HAG", aliases: ["Hag"]),
        .init(name: "Zechariah", code: "ZEC", aliases: ["Zech"]),
        .init(name: "Malachi", code: "MAL", aliases: ["Mal"]),
        .init(name: "Matthew", code: "MAT", aliases: ["Matt", "Mt"]),
        .init(name: "Mark", code: "MRK", aliases: ["Mk", "Mrk"]),
        .init(name: "Luke", code: "LUK", aliases: ["Lk"]),
        .init(name: "John", code: "JHN", aliases: ["Jn", "Jhn"]),
        .init(name: "Acts", code: "ACT", aliases: ["Act"]),
        .init(name: "Romans", code: "ROM", aliases: ["Rom", "Rm"]),
        .init(name: "1 Corinthians", code: "1CO", aliases: ["1 Cor", "1 Co"]),
        .init(name: "2 Corinthians", code: "2CO", aliases: ["2 Cor", "2 Co"]),
        .init(name: "Galatians", code: "GAL", aliases: ["Gal"]),
        .init(name: "Ephesians", code: "EPH", aliases: ["Eph"]),
        .init(name: "Philippians", code: "PHP", aliases: ["Phil", "Php"]),
        .init(name: "Colossians", code: "COL", aliases: ["Col"]),
        .init(name: "1 Thessalonians", code: "1TH", aliases: ["1 Thess", "1 Th"]),
        .init(name: "2 Thessalonians", code: "2TH", aliases: ["2 Thess", "2 Th"]),
        .init(name: "1 Timothy", code: "1TI", aliases: ["1 Tim", "1 Ti"]),
        .init(name: "2 Timothy", code: "2TI", aliases: ["2 Tim", "2 Ti"]),
        .init(name: "Titus", code: "TIT", aliases: ["Tit"]),
        .init(name: "Philemon", code: "PHM", aliases: ["Phlm", "Philem"]),
        .init(name: "Hebrews", code: "HEB", aliases: ["Heb"]),
        .init(name: "James", code: "JAS", aliases: ["Jas", "Jms"]),
        .init(name: "1 Peter", code: "1PE", aliases: ["1 Pet", "1 Pt"]),
        .init(name: "2 Peter", code: "2PE", aliases: ["2 Pet", "2 Pt"]),
        .init(name: "1 John", code: "1JN", aliases: ["1 Jn", "1 Jhn"]),
        .init(name: "2 John", code: "2JN", aliases: ["2 Jn", "2 Jhn"]),
        .init(name: "3 John", code: "3JN", aliases: ["3 Jn", "3 Jhn"]),
        .init(name: "Jude", code: "JUD", aliases: ["Jud"]),
        .init(name: "Revelation", code: "REV", aliases: ["Rev", "Revelations", "Rv"]),
    ]
}
