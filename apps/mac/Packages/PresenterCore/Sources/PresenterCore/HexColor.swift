import Foundation

/// A color as hex text, the way people type and paste it into a color
/// field: "#1E2A44", "1E2A44", "#FFF" or "#1E2A44CC", with stray spaces,
/// quotes or a trailing semicolon from a stylesheet. Documents store the
/// app's "#RRGGBBAA"; a field shows "#RRGGBB" until the color has alpha.
public struct HexColor: Equatable, Hashable, Sendable {
    /// sRGB channels and alpha, 0 to 1.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
        self.red = unit(red)
        self.green = unit(green)
        self.blue = unit(blue)
        self.alpha = unit(alpha)
    }

    /// Three digits (#RGB, each doubled), six (#RRGGBB, opaque) or eight
    /// (#RRGGBBAA), with or without "#" or "0x"; nil for anything else.
    public init?(_ text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines.union(Self.wrapping)))
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        } else if digits.lowercased().hasPrefix("0x") {
            digits = digits.dropFirst(2)
        }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded: String
        switch digits.count {
        case 3: expanded = digits.map { "\($0)\($0)" }.joined() + "FF"
        case 6: expanded = String(digits) + "FF"
        case 8: expanded = String(digits)
        default: return nil
        }
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        func channel(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    /// Quotes and the semicolon a value copied out of CSS brings along.
    private static let wrapping = CharacterSet(charactersIn: "\"'`;")

    /// The app's stored form, "#RRGGBBAA".
    public var stored: String { format(alpha: true) }

    /// What a hex field shows: "#RRGGBB" for an opaque color (or whenever
    /// the field has no opacity), "#RRGGBBAA" otherwise.
    public func display(allowsAlpha: Bool = true) -> String {
        format(alpha: allowsAlpha && byte(alpha) != 0xFF)
    }

    /// The same color, fully opaque.
    public var opaque: HexColor { HexColor(red: red, green: green, blue: blue) }

    /// Typed or pasted text in the stored form; nil when it isn't a color.
    public static func normalized(_ text: String) -> String? {
        HexColor(text)?.stored
    }

    private func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }

    private func format(alpha includeAlpha: Bool) -> String {
        includeAlpha
            ? String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
            : String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
