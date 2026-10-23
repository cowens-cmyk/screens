import Foundation

/// A section name read the way a band reads it: "V1", "Verse 1" and
/// "verse1" are the same verse, "CH" is the chorus, "Pre Chorus" and "PC"
/// are one thing. Anthem names sections from its tracks and Screens from
/// whoever built the slides, so both sides go through this before they are
/// compared.
public struct SectionLabel: Hashable, Sendable {
    /// The canonical kind ("verse", "pre-chorus", "turnaround"), or the
    /// cleaned name itself when it is not a kind we know ("coda").
    public var kind: String
    public var number: Int?
    /// Whether `kind` is one of the known kinds.
    public var known: Bool
    /// The name lowercased with punctuation and repeat marks removed, for an
    /// exact match before any kind rules ("Final Chorus" finds "final chorus").
    public var cleaned: String

    public init(_ raw: String) {
        let cleaned = Self.clean(raw)
        self.cleaned = cleaned
        var words = cleaned
        for prefix in ["final ", "last "] where words.hasPrefix(prefix) {
            words = String(words.dropFirst(prefix.count))
        }
        for (joined, canonical) in Self.joined {
            words = words.replacingOccurrences(of: joined, with: canonical)
        }
        // "verse 2", "v2", "chorus 1a": letters, then an optional number.
        var letters = words
        var number: Int?
        if let match = words.firstMatch(of: #/^([a-z\- ]*?)\s*(\d+)[a-z]?$/#) {
            letters = String(match.1).trimmingCharacters(in: .whitespaces)
            number = Int(match.2)
        }
        if let kind = Self.aliases[letters] {
            self.kind = kind
            self.number = number
            self.known = true
        } else {
            self.kind = letters.isEmpty ? cleaned : letters
            self.number = letters.isEmpty ? nil : number
            self.known = false
        }
    }

    /// Instrumental by name: no lyrics expected on screen.
    public var isInstrumental: Bool { Self.instrumentalKinds.contains(kind) }

    /// Usually instrumental, sometimes sung: an intro or outro with lyrics on
    /// its slides is compared like any other section.
    public var mayBeInstrumental: Bool { isInstrumental || Self.softInstrumentalKinds.contains(kind) }

    /// "V1", "C", "PC", "B2" — for the one-line order diff.
    public var short: String {
        let base = Self.shorts[kind] ?? kind.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        guard let number else { return base }
        return Self.shorts[kind] != nil ? "\(base)\(number)" : "\(base) \(number)"
    }

    /// "Verse 3", "Pre-Chorus", "Tag".
    public var display: String {
        let base = Self.displays[kind] ?? kind.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return number.map { "\(base) \($0)" } ?? base
    }

    /// Lowercased, accents folded, "(x2)" / "x2" repeat marks and brackets
    /// dropped, punctuation to spaces.
    static func clean(_ raw: String) -> String {
        var text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        text = text.replacing(#/\([^)]*\)|\[[^\]]*\]/#, with: " ")
        text = text.replacing(#/\s+(x\s*\d+|\d+\s*x)\s*$/#, with: "")
        text = String(text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " })
        text = text.split(separator: " ").joined(separator: " ")
        // Keep the hyphen only between words ("pre-chorus").
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return text
    }

    /// Two-word spellings folded to one before the alias lookup.
    static let joined: [(String, String)] = [
        ("pre chorus", "pre-chorus"), ("prechorus", "pre-chorus"),
        ("post chorus", "post-chorus"), ("postchorus", "post-chorus"),
        ("turn around", "turnaround"), ("turn-around", "turnaround"),
        ("inter lude", "interlude"), ("break down", "breakdown"),
    ]

    static let aliases: [String: String] = [
        "v": "verse", "vs": "verse", "vrs": "verse", "verse": "verse", "verses": "verse",
        "c": "chorus", "ch": "chorus", "cho": "chorus", "chor": "chorus", "chorus": "chorus",
        "pc": "pre-chorus", "pre": "pre-chorus", "pre-chorus": "pre-chorus", "pch": "pre-chorus",
        "post": "post-chorus", "post-chorus": "post-chorus", "poc": "post-chorus",
        "b": "bridge", "br": "bridge", "bri": "bridge", "brg": "bridge", "bridge": "bridge",
        "t": "tag", "tg": "tag", "tag": "tag",
        "i": "intro", "in": "intro", "intro": "intro",
        "o": "outro", "out": "outro", "outro": "outro",
        "e": "ending", "end": "ending", "ending": "ending",
        "inst": "instrumental", "instr": "instrumental", "instrumental": "instrumental",
        "music": "instrumental", "band": "instrumental",
        "int": "interlude", "interlude": "interlude",
        "ta": "turnaround", "turn": "turnaround", "turnaround": "turnaround",
        "vamp": "vamp", "vp": "vamp",
        "r": "refrain", "ref": "refrain", "refrain": "refrain",
        "h": "hook", "hook": "hook",
        "break": "break", "brk": "break", "breakdown": "break",
        "solo": "solo",
        "blank": "blank", "empty": "blank", "rest": "blank",
    ]

    static let instrumentalKinds: Set<String> = ["instrumental", "interlude", "turnaround", "break", "solo", "blank"]
    static let softInstrumentalKinds: Set<String> = ["intro", "outro", "ending"]

    static let shorts: [String: String] = [
        "verse": "V", "chorus": "C", "pre-chorus": "PC", "post-chorus": "PoC", "bridge": "B",
        "tag": "T", "intro": "In", "outro": "Out", "ending": "End", "instrumental": "Inst",
        "interlude": "Int", "turnaround": "TA", "vamp": "Vamp", "refrain": "R", "hook": "H",
        "break": "Brk", "solo": "Solo", "blank": "Blank",
    ]

    static let displays: [String: String] = [
        "verse": "Verse", "chorus": "Chorus", "pre-chorus": "Pre-Chorus", "post-chorus": "Post-Chorus",
        "bridge": "Bridge", "tag": "Tag", "intro": "Intro", "outro": "Outro", "ending": "Ending",
        "instrumental": "Instrumental", "interlude": "Interlude", "turnaround": "Turnaround",
        "vamp": "Vamp", "refrain": "Refrain", "hook": "Hook", "break": "Break", "solo": "Solo",
        "blank": "Blank",
    ]
}
