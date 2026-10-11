import Foundation

/// Finds Bible references in live speech: "turn to Genesis 32", "John
/// chapter three verse sixteen", "first Corinthians thirteen four through
/// seven", "Psalm 23:1".
public enum SpokenReference {

    public static func references(in transcript: String) -> [BibleReference] {
        let words = normalize(transcript).split(separator: " ").map(String.init)
        var found: [BibleReference] = []
        for start in words.indices {
            let rest = words[start...].joined(separator: " ")
            guard startsWithBook(rest) else { continue }
            let window = words[start..<min(words.count, start + 6)].joined(separator: " ")
            guard let reference = BibleReference.parse(window) else { continue }
            // "1 John 3" also starts a match at "John 3"; keep the longer one.
            if let last = found.last, last.chapter == reference.chapter,
               last.book.name.hasSuffix(reference.book.name) {
                continue
            }
            if !found.contains(reference) { found.append(reference) }
        }
        return found
    }

    private static func startsWithBook(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return BibleReference.books.contains { book in
            ([book.name] + book.aliases).contains {
                lowered.hasPrefix($0.lowercased() + " ") || lowered.hasPrefix($0.lowercased().replacingOccurrences(of: " ", with: "") + " ")
            }
        }
    }

    /// Spoken numbers to digits and "chapter X verse Y" to "X:Y".
    public static func normalize(_ text: String) -> String {
        var words = text.lowercased()
            .replacingOccurrences(of: "[,;!?]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\.(\s|$)"#, with: "$1$2", options: .regularExpression)
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
