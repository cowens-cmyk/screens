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

    static let chapterMarker = "§chapter"

    /// `recent` is what this sermon has mentioned so far, newest first; it
    /// helps pick between two readings of the same words.
    public static func detections(in transcript: String, recent: [BibleReference] = []) -> [SpokenDetection] {
        let words = normalize(transcript).split(separator: " ").map(String.init)
        var found: [SpokenDetection] = []
        var index = 0
        while index < words.count {
            guard let (book, length) = spokenBook(in: words, at: index) else {
                index += 1
                continue
            }
            var next = index + length
            var saidChapter = next < words.count && words[next] == chapterMarker
            if saidChapter { next += 1 }
            // "Turn to Genesis 32", "open your Bibles to Romans 12": announcing
            // where to turn names the chapter.
            let lead = words[max(0, index - 5)..<index]
            if lead.contains(where: { ["turn", "turning", "open", "opening", "flip"].contains($0) }) { saidChapter = true }
            // A book name only counts with a number right after it, so
            // "mark my words" or "the book of Acts" never match.
            guard next < words.count, var detection = detection(book: book, numbers: words[next]) else {
                index = next
                continue
            }
            detection = likely(detection, saidChapter: saidChapter, recent: recent + found.map(\.reference))
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

    /// Puts the most likely reading first. Saying "chapter" settles it; then
    /// a chapter already mentioned in this sermon; then chapters people cite
    /// whole (Psalm 23, Romans 8); otherwise chapter and verse, which sermons
    /// cite far more often than whole chapters.
    static func likely(_ detection: SpokenDetection, saidChapter: Bool, recent: [BibleReference]) -> SpokenDetection {
        guard detection.ambiguous else { return detection }
        let readings = [detection.reference] + detection.alternatives
        guard let whole = readings.first(where: { $0.startVerse == nil }),
              let verse = readings.first(where: { $0.startVerse != nil })
        else { return detection }
        func pick(_ chosen: BibleReference) -> SpokenDetection {
            SpokenDetection(reference: chosen, alternatives: readings.filter { $0 != chosen })
        }
        if saidChapter { return pick(whole) }
        let sameBook = recent.filter { $0.book == whole.book }
        if sameBook.contains(where: { $0.chapter == verse.chapter }) { return pick(verse) }
        if sameBook.contains(where: { $0.chapter == whole.chapter }) { return pick(whole) }
        if wellKnownChapters[whole.book.code]?.contains(whole.chapter) == true { return pick(whole) }
        return pick(verse)
    }

    /// Chapters often named on their own in a sermon.
    static let wellKnownChapters: [String: Set<Int>] = [
        "GEN": [12, 15, 22, 37, 50], "EXO": [14, 20], "JOS": [24], "1SA": [17], "2SA": [11],
        "1KI": [18, 19], "JOB": [38], "PSA": [19, 22, 23, 27, 37, 46, 51, 63, 84, 90, 91, 103, 119, 121, 139, 150],
        "PRO": [31], "ISA": [40, 53, 55], "JER": [29], "EZK": [37], "DAN": [3, 6],
        "MAT": [11, 13, 18, 25, 28], "MRK": [16], "LUK": [10, 15, 24], "JHN": [10, 11, 14, 15, 17, 20, 21],
        "ACT": [10, 15, 17], "ROM": [12], "1CO": [12, 13, 15], "2CO": [12], "HEB": [11, 12],
        "REV": [12, 21, 22],
    ]

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
                // Kept as a marker: "John chapter 11" is the chapter, never 1:1.
                output.append(chapterMarker)
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
            let beforeNumber = output.count >= 2 && output[output.count - 2] == chapterMarker
                ? Array(output.dropLast(2)) + [output[output.count - 1]] : output
            if let number = Int(word), let last = output.last, Int(last) != nil,
               beforeNumber.count >= 2, number > 0,
               BibleReference.book(named: beforeNumber[beforeNumber.count - 2]) != nil
                || (beforeNumber.count >= 3 && BibleReference.book(
                    named: beforeNumber[beforeNumber.count - 3] + " " + beforeNumber[beforeNumber.count - 2]) != nil) {
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
