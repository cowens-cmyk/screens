import Foundation

/// The `screens-theme.json` Claude Design adds to a series download, so the
/// whole download becomes a series theme in one step. Fonts are lists, best
/// first, so a font that isn't installed falls back to the next.
public struct SeriesExport: Codable, Equatable, Sendable {
    public var series: String
    public var background: String?
    public var lowerThird: String?
    public var headingFont: [String]?
    public var bodyFont: [String]?
    public var scriptureFont: [String]?
    public var headingAllCaps: Bool?
    public var textColor: String?
    public var accentColor: String?
    public var lowerThirdTextColor: String?
    public var lowerThirdAccentColor: String?

    public static let fileName = "screens-theme.json"

    /// Reads the file leniently: a single font string is taken as a
    /// one-item list.
    public static func decode(_ data: Data) throws -> SeriesExport {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a JSON object"))
        }
        for key in ["headingFont", "bodyFont", "scriptureFont"] {
            if let single = object[key] as? String { object[key] = [single] }
        }
        return try JSONDecoder().decode(SeriesExport.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The part to paste into Claude Design after the artwork is made.
    public static func exportPrompt(series: String) -> String {
        """
        Export the "\(series)" sermon series for my presentation app as one ZIP containing exactly these three files:

        1. background.png — 1920×1080, the series background with NO words on it. Used behind the message title, a sermon point (one large line), a scripture passage (a paragraph plus its reference), a point with its verse and song lyrics, so keep the middle calm enough for large text.
        2. lower-third.png — 1920×1080 transparent PNG: only a bar or shape in the series style across the bottom ~200 pixels (it may fade upward a little), for text over a camera shot. Everything else fully transparent.
        3. screens-theme.json — exactly this shape, filled in:
        {
          "series": "\(series)",
          "background": "background.png",
          "lowerThird": "lower-third.png",
          "headingFont": ["<series heading font and weight, e.g. Gotham Black>", "<a font that ships with macOS as a fallback, e.g. Avenir Next Heavy>"],
          "bodyFont": ["<body font and weight>", "<macOS fallback>"],
          "scriptureFont": ["<scripture font, often the body italic>", "<macOS fallback>"],
          "headingAllCaps": true,
          "textColor": "#RRGGBB (text on the background)",
          "accentColor": "#RRGGBB (scripture references on the background)",
          "lowerThirdTextColor": "#RRGGBB (text on the lower-third bar)",
          "lowerThirdAccentColor": "#RRGGBB (references on the bar)"
        }
        Make sure each text color reads clearly on what it sits on.
        """
    }
}
