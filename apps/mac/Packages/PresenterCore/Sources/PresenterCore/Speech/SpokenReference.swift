import Foundation

/// A reference heard in speech, and any other way the same words could be
/// read. Recognizers write "John one one" and "John eleven" the same way
/// ("John 11"), so a bare number that is both a chapter and a chapter:verse
/// is ambiguous and waits for someone to pick.
public struct SpokenDetection: Hashable, Sendable {
    public var reference: BibleReference
    public var alternatives: [BibleReference]
    public var ambiguous: Bool { !alternatives.isEmpty }
}

/// Finds Bible references in live speech: "turn to Genesis 32", "John
/// chapter three verse sixteen", "first Corinthians thirteen four through
/// seven", "Psalm 23:1". Every reference is checked against the book's real
/// chapters, so "John 316" (how recognizers write "John three sixteen")
/// becomes John 3:16 and never a chapter that doesn't exist.
public enum SpokenReference {

    public static func references(in transcript: String) -> [BibleReference] {
        detections(in: transcript).map(\.reference)
    }

    public static func detections(in transcript: String) -> [SpokenDetection] {
        let words = normalize(transcript).split(separator: " ").map(String.init)
        var found: [SpokenDetection] = []
        var index = 0
        while index < words.count {
            guard let (book, length) = spokenBook(in: words, at: index) else {
                index += 1
                continue
            }
            let next = index + length
            // A book name only counts with a number right after it, so
            // "mark my words" or "the book of Acts" never match.
            guard next < words.count, let detection = detection(book: book, numbers: words[next]) else {
                index = next
                continue
            }
            if !found.contains(where: { $0.reference == detection.reference }) { found.append(detection) }
            index = next + 1
        }
        return found
    }

    /// The longest book name starting at `index` ("1 John" before "John").
    private static func spokenBook(in words: [String], at index: Int) -> (BibleBook, Int)? {
        for length in stride(from: min(3, words.count - index), through: 1, by: -1) {
            let name = words[index..<index + length].joined(separator: " ")
            if let book = spokenNames[name] { return (book, length) }
        }
        return nil
    }

    /// Full names and the longer aliases. Short abbreviations ("Is", "Am",
    /// "Ex") are left out: in speech they're ordinary words.
    private static let spokenNames: [String: BibleBook] = {
        var table: [String: BibleBook] = [:]
        for book in BibleReference.books {
            let names = [book.name] + book.aliases.filter { $0.count >= 5 && !$0.contains(".") }
            for name in names { table[name.lowercased()] = book }
        }
        if let revelation = BibleReference.book(named: "Revelation") { table["revelations"] = revelation }
        if let psalms = BibleReference.book(named: "Psalms") { table["psalm"] = psalms }
        return table
    }()

    private static let numbers = try! NSRegularExpression(pattern: #"^(\d+)(?::(\d+))?(?:-(\d+)(?::(\d+))?)?$"#)

    /// Reads "3:16", "3:16-18", "3:16-4:2", "23" or "316" after a book.
    static func detection(book: BibleBook, numbers text: String) -> SpokenDetection? {
        guard let match = numbers.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let first = group(1), let firstNumber = Int(first) else { return nil }
        let verse = group(2).flatMap(Int.init)
        let endA = group(3).flatMap(Int.init)
        let endB = group(4).flatMap(Int.init)

        func valid(_ reference: BibleReference) -> BibleReference? {
            book.isValid(reference) ? reference : nil
        }
        func range(chapter: Int, verse: Int) -> BibleReference {
            if let endA, let endB {
                return BibleReference(book: book, chapter: chapter, startVerse: verse, endChapter: endA, endVerse: endB)
            }
            if let endA, endA > verse {
                return BibleReference(book: book, chapter: chapter, startVerse: verse, endVerse: endA)
            }
            return BibleReference(book: book, chapter: chapter, startVerse: verse)
        }

        if let verse {
            return valid(range(chapter: firstNumber, verse: verse)).map { SpokenDetection(reference: $0, alternatives: []) }
        }
        // "Jude 5" is verse 5: these books have one chapter.
        if book.chapterCount == 1 {
            return valid(range(chapter: 1, verse: firstNumber)).map { SpokenDetection(reference: $0, alternatives: []) }
        }
        let split = splitChapterVerse(first, book: book).flatMap { valid(range(chapter: $0.chapter, verse: $0.verse)) }
        guard firstNumber <= book.chapterCount else {
            // No such chapter, so the digits ran together: "316" is 3:16.
            return split.map { SpokenDetection(reference: $0, alternatives: []) }
        }
        guard let chapter = valid(BibleReference(book: book, chapter: firstNumber)) else { return nil }
        return SpokenDetection(reference: chapter, alternatives: split.map { [$0] } ?? [])
    }

    /// "316" → 3:16, "11910" → 119:10: the longest leading chapter that
    /// exists, with the rest as a verse. No part may start with a zero.
    static func splitChapterVerse(_ digits: String, book: BibleBook) -> (chapter: Int, verse: Int)? {
        guard digits.count >= 2, digits.allSatisfy(\.isNumber) else { return nil }
        for length in stride(from: min(3, digits.count - 1), through: 1, by: -1) {
            let chapterText = digits.prefix(length), verseText = digits.dropFirst(length)
            guard chapterText.first != "0", verseText.first != "0",
                  let chapter = Int(chapterText), let verse = Int(verseText),
                  (1...book.chapterCount).contains(chapter), (1...176).contains(verse)
            else { continue }
            return (chapter, verse)
        }
        return nil
    }

    /// Spoken numbers to digits and "chapter X verse Y" to "X:Y".
    public static func normalize(_ text: String) -> String {
        var words = text.lowercased()
            .replacingOccurrences(of: "[,;!?]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\s*:\s*(\d)"#, with: "$1:$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1:$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\.(\s|$)"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\s*[–—-]\s*(\d)"#, with: "$1-$2", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        words = mergeNumberWords(words)
        var output: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            switch word {
            case "chapter", "chapters":
                index += 1
                continue
            case "verse", "verses", "vs", "v":
                if let last = output.last, Int(last) != nil, index + 1 < words.count, Int(words[index + 1]) != nil {
                    output[output.count - 1] = "\(last):\(words[index + 1])"
                    index += 2
                    continue
                }
            case "through", "thru", "to", "until":
                if let last = output.last, last.contains(":") || Int(last) != nil,
                   index + 1 < words.count, Int(words[index + 1]) != nil {
                    output[output.count - 1] = "\(last)-\(words[index + 1])"
                    index += 2
                    continue
                }
            case "first", "1st": output.append("1"); index += 1; continue
            case "second", "2nd": output.append("2"); index += 1; continue
            case "third", "3rd": output.append("3"); index += 1; continue
            case "psalm", "psalms", "song", "songs", "of", "solomon":
                break
            default:
                break
            }
            // "John 3 16" — a chapter directly followed by a verse number.
            if let number = Int(word), let last = output.last, Int(last) != nil,
               output.count >= 2, number > 0,
               BibleReference.book(named: output[output.count - 2]) != nil
                || (output.count >= 3 && BibleReference.book(
                    named: output[output.count - 3] + " " + output[output.count - 2]) != nil) {
                output[output.count - 1] = "\(last):\(number)"
                index += 1
                continue
            }
            output.append(word)
            index += 1
        }
        return output.joined(separator: " ")
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// "one hundred nineteen" → "119", "twenty three" → "23", "twenty-three" → "23".
    static func mergeNumberWords(_ words: [String]) -> [String] {
        var output: [String] = []
        var current: Int?
        func flush() {
            if let current { output.append(String(current)) }
            current = nil
        }
        for raw in words {
            let parts = raw.split(separator: "-").map(String.init)
            var consumed = true
            for part in parts {
                if let value = units[part] {
                    if let c = current, c % 10 == 0, c >= 20 || c >= 100 { current = c + value }
                    else if current != nil { flush(); current = value }
                    else { current = value }
                } else if let value = tens[part] {
                    if let c = current, c >= 100, c % 100 == 0 { current = c + value }
                    else { flush(); current = value }
                } else if part == "hundred" {
                    current = (current ?? 1) * 100
                } else if part == "and", current.map({ $0 >= 100 }) == true {
                    continue
                } else {
                    consumed = false
                }
            }
            if !consumed {
                flush()
                output.append(raw)
            }
        }
        flush()
        return output
    }
}
