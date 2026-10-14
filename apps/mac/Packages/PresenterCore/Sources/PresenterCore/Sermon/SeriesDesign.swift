import Foundation

/// A sermon series' artwork and type, drawn by Claude: a text-free
/// 1920×1080 background and a transparent lower-third bar, both as SVG the
/// app renders to images, plus fonts and colors.
public struct SeriesDesign: Codable, Equatable, Sendable {
    public var backgroundSVG: String
    public var lowerThirdSVG: String
    public var headingFont: String
    public var bodyFont: String
    public var textColor: String
    public var accentColor: String
    public var lowerThirdTextColor: String
    public var lowerThirdAccentColor: String
    public var headingAllCaps: Bool

    /// The structured-output schema, with fonts limited to ones installed.
    public static func schema(fonts: [String]) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["backgroundSVG", "lowerThirdSVG", "headingFont", "bodyFont", "textColor", "accentColor",
                         "lowerThirdTextColor", "lowerThirdAccentColor", "headingAllCaps"],
            "properties": [
                "backgroundSVG": ["type": "string"],
                "lowerThirdSVG": ["type": "string"],
                "headingFont": ["type": "string", "enum": fonts],
                "bodyFont": ["type": "string", "enum": fonts],
                "textColor": ["type": "string"],
                "accentColor": ["type": "string"],
                "lowerThirdTextColor": ["type": "string"],
                "lowerThirdAccentColor": ["type": "string"],
                "headingAllCaps": ["type": "boolean"],
            ],
        ]
    }

    public static let instructions = """
    You design the look of a church sermon series for the slides shown on screen during the message. The presentation app adds all words itself; you only make artwork and pick type and color.

    Return:
    - backgroundSVG: one complete SVG, width="1920" height="1080" viewBox="0 0 1920 1080". Text-free artwork that suits the series title and theme: tasteful, modern, a little bold — gradients, light, abstract or geometric shapes, a hint of the theme. Keep the center calm and dark (or light) enough that large text in textColor reads clearly over it.
    - lowerThirdSVG: one complete SVG, same size, transparent everywhere except a bar or shape across the bottom of the frame (solid from about y 880 to 1080, optionally fading above) for text to sit on over a camera shot of the pastor. It must match the background's style. No full-frame fill.
    - headingFont and bodyFont from the allowed list. headingAllCaps if the style suits capitals.
    - textColor and accentColor for text over the background; lowerThirdTextColor and lowerThirdAccentColor for text over the bar. All #RRGGBB, each clearly readable on what it sits on.

    SVG rules: only rect, circle, ellipse, line, polyline, polygon, path, g, linearGradient, radialGradient, stop, with fill, stroke, opacity and transform. No text, no images, no filters, no masks, no external references, no scripts.
    """

    /// Removes anything the renderer shouldn't draw (text, scripts, links)
    /// as a guard on top of the instructions.
    public static func sanitize(_ svg: String) -> String {
        var cleaned = svg
        for pattern in [#"<text[\s\S]*?</text>"#, #"<script[\s\S]*?</script>"#, #"<image[^>]*>"#, #"<foreignObject[\s\S]*?</foreignObject>"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return cleaned
    }

    /// Normalizes "#RRGGBB" to the app's "#RRGGBBAA".
    public static func color(_ hex: String, fallback: String) -> String {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return fallback }
        return "#" + digits.uppercased() + (digits.count == 6 ? "FF" : "")
    }
}
