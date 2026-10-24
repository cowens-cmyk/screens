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
    /// as a guard on top of the instructions. A Claude Design download's
    /// artwork often carries its picture inside the SVG as a `data:` image,
    /// so `keepEmbeddedImages` keeps those; an image or link pointing
    /// anywhere else is still removed, so drawing the file never reaches
    /// out to the network or the disk.
    public static func sanitize(_ svg: String, keepEmbeddedImages: Bool = false) -> String {
        var cleaned = svg
        for pattern in [#"<text[\s\S]*?</text>"#, #"<script[\s\S]*?</script>"#, #"<script[^>]*/>"#,
                        #"<foreignObject[\s\S]*?</foreignObject>"#, #"<foreignObject[^>]*/>"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        cleaned = replacingMatches(of: #"<image\b[^>]*>"#, in: cleaned) { tag in
            let links = hrefs(in: tag)
            return keepEmbeddedImages && !links.isEmpty && links.allSatisfy(isEmbeddedImage) ? tag : ""
        }
        cleaned = cleaned.replacingOccurrences(of: #"</image\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Links elsewhere (a <use> of another file, a stylesheet's url() or
        // @import) point outside the file; references within it ("#id")
        // and embedded images stay.
        cleaned = replacingMatches(of: #"\s(?:xlink:)?href\s*=\s*(?:"[^"]*"|'[^']*')"#, in: cleaned) { attribute in
            let value = hrefs(in: attribute).first ?? ""
            return value.hasPrefix("#") || (keepEmbeddedImages && isEmbeddedImage(value)) ? attribute : ""
        }
        cleaned = cleaned.replacingOccurrences(of: #"@import[^;]*;?"#, with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = replacingMatches(of: #"url\(\s*(?:"[^"]*"|'[^']*'|[^)]*)\s*\)"#, in: cleaned) { call in
            let inner = call.dropFirst(4).dropLast().trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return inner.hasPrefix("#") || (keepEmbeddedImages && isEmbeddedImage(inner)) ? call : "none"
        }
        return cleaned
    }

    /// The pictures carried inside an SVG as base64 `data:` images, in the
    /// order they appear. A download's SVG is often only a wrapper around
    /// one, which can be used directly if the SVG itself won't draw.
    public static func embeddedImages(_ svg: String) -> [Data] {
        captures(of: #"<image\b[^>]*?(?:xlink:)?href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: svg).compactMap { href in
            let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEmbeddedImage(value), let comma = value.firstIndex(of: ","),
                  value[..<comma].lowercased().hasSuffix(";base64")
            else { return nil }
            let encoded = value[value.index(after: comma)...].filter { !$0.isWhitespace }
            return Data(base64Encoded: String(encoded))
        }
    }

    private static func isEmbeddedImage(_ href: String) -> Bool {
        href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data:image/")
    }

    /// The values of every href and xlink:href in a tag.
    private static func hrefs(in tag: String) -> [String] {
        captures(of: #"(?:xlink:)?href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag)
    }

    /// The first capture group that matched, for each match.
    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            (1..<match.numberOfRanges).lazy
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
                .map { source.substring(with: $0) }
        }
    }

    private static func replacingMatches(of pattern: String, in text: String, with replace: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replace(source.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// The drawing's own shape, from its viewBox (or its width and height
    /// when it has none), so it can be drawn without being stretched.
    public static func svgSize(_ svg: String) -> (width: Double, height: Double)? {
        guard let open = svg.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(svg[open])
        func attribute(_ name: String) -> String? {
            captures(of: #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag).first
        }
        if let box = attribute("viewBox") {
            let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 { return (numbers[2], numbers[3]) }
        }
        // "1920" or "1920px"; a percentage says nothing about the shape.
        func length(_ name: String) -> Double? {
            guard let value = attribute(name)?.trimmingCharacters(in: .whitespaces), !value.hasSuffix("%"),
                  let number = Double(value.replacingOccurrences(of: "px", with: "")), number > 0
            else { return nil }
            return number
        }
        guard let width = length("width"), let height = length("height") else { return nil }
        return (width, height)
    }

    /// Normalizes "#RRGGBB" (or "#RGB", "#RRGGBBAA") to the app's "#RRGGBBAA".
    public static func color(_ hex: String, fallback: String) -> String {
        HexColor.normalized(hex) ?? fallback
    }
}
