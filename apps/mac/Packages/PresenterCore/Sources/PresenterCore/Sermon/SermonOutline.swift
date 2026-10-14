import Foundation

/// What Claude reads out of a week's sermon notes: the slides, in order.
public struct SermonOutline: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A point on its own.
        case point
        /// A passage, read on screen.
        case scripture
        /// A point with the verse that supports it.
        case pointScripture

        public var title: String {
            switch self {
            case .point: "Point"
            case .scripture: "Scripture"
            case .pointScripture: "Point + Scripture"
            }
        }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var kind: Kind
        /// The point's words. For scripture, the reference as written.
        public var text: String
        /// The Bible reference to look up (scripture and point + scripture);
        /// empty for a plain point.
        public var reference: String

        enum CodingKeys: String, CodingKey { case kind, text, reference }

        public init(kind: Kind, text: String, reference: String = "") {
            self.kind = kind
            self.text = text
            self.reference = reference
        }
    }

    public var title: String
    public var slides: [Item]

    public init(title: String, slides: [Item]) {
        self.title = title
        self.slides = slides
    }

    /// The JSON shape Claude's answer must follow (structured outputs).
    public static var schema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "slides"],
        "properties": [
            "title": ["type": "string"],
            "slides": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["kind", "text", "reference"],
                    "properties": [
                        "kind": ["type": "string", "enum": Kind.allCases.map(\.rawValue)],
                        "text": ["type": "string"],
                        "reference": ["type": "string"],
                    ],
                ],
            ],
        ],
    ] }

    public static let instructions = """
    You turn a pastor's sermon notes into the slides shown during the message at a church service.

    Return the slides in the order they come up in the sermon. Every slide is one of three kinds:
    - "point": a main point or sub-point the congregation should see. text is the point in the pastor's wording, trimmed of filler (fill-in-the-blank points: write them with the blank filled in). reference is empty.
    - "scripture": a Bible passage the notes ask to read or show. reference is the passage as a reference, e.g. "Genesis 32:22-32" or "Romans 8:28"; text repeats it. Don't write out verse text — the app looks it up.
    - "pointScripture": a point the notes tie directly to one short verse (one or two verses). text is the point, reference is the verse.

    Leave out the pastor's private notes, stories, transitions and stage directions — only what belongs on screen. title is the sermon's title.
    """


    /// Reads Claude's JSON answer.
    public static func decode(_ json: String) throws -> SermonOutline {
        try JSONDecoder().decode(SermonOutline.self, from: Data(json.utf8))
    }
}
