import Foundation

/// An sRGB color with channels from 0 to 1, for the arithmetic a series
/// theme made from a photo needs: palettes, mixing and WCAG contrast.
public struct SeriesColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public static let white = SeriesColor(red: 1, green: 1, blue: 1)
    public static let black = SeriesColor(red: 0, green: 0, blue: 0)

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" (alpha ignored), read as HexColor
    /// reads them; nil for anything else.
    public init?(hex: String) {
        guard let color = HexColor(hex) else { return nil }
        self.init(red: color.red, green: color.green, blue: color.blue)
    }

    /// The app's "#RRGGBBAA".
    public func hex(alpha: Double = 1) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    public func contrast(with other: SeriesColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Part way to `other`: 0 is self, 1 is other.
    public func mixed(with other: SeriesColor, amount: Double) -> SeriesColor {
        let t = min(max(amount, 0), 1)
        return SeriesColor(red: red + (other.red - red) * t,
                           green: green + (other.green - green) * t,
                           blue: blue + (other.blue - blue) * t)
    }

    /// This color at `alpha` laid over `backdrop`.
    public func composited(alpha: Double, over backdrop: SeriesColor) -> SeriesColor {
        backdrop.mixed(with: self, amount: alpha)
    }

    /// HSV saturation, 0 for greys.
    public var saturation: Double {
        let high = max(red, green, blue)
        return high == 0 ? 0 : (high - min(red, green, blue)) / high
    }

    /// HSV value.
    public var brightness: Double { max(red, green, blue) }

    func distanceSquared(to other: SeriesColor) -> Double {
        let (dr, dg, db) = (red - other.red, green - other.green, blue - other.blue)
        // Weighted toward green the way the eye is, so near-identical
        // greens don't split into two swatches while blues merge.
        return 2 * dr * dr + 4 * dg * dg + 3 * db * db
    }
}

/// Keeps text readable: WCAG asks 4.5:1 for body text, and on a projector
/// or a stream the real contrast is only ever lower than on paper.
public enum SeriesContrast {
    public static let minimum = 4.5

    /// The worst contrast the text has against any of the samples.
    public static func worst(_ text: SeriesColor, on samples: [SeriesColor]) -> Double {
        samples.map { text.contrast(with: $0) }.min() ?? 21
    }

    /// `text` unchanged when it reads on every sample; otherwise moved the
    /// least distance toward white or black (whichever gets there) so it
    /// does. The hue survives a small nudge, so an accent stays an accent.
    /// When neither end can reach the minimum, the better of white or black.
    public static func readable(_ text: SeriesColor, on samples: [SeriesColor], minimum: Double = minimum) -> SeriesColor {
        guard !samples.isEmpty, worst(text, on: samples) < minimum else { return text }
        var best: SeriesColor?
        var bestAmount = Double.infinity
        for end in [SeriesColor.white, .black] where worst(end, on: samples) >= minimum {
            // Contrast rises steadily toward the end that passes, so a
            // bisection finds the smallest move.
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if worst(text.mixed(with: end, amount: mid), on: samples) >= minimum { high = mid } else { low = mid }
            }
            if high < bestAmount {
                bestAmount = high
                best = text.mixed(with: end, amount: high)
            }
        }
        if let best { return best }
        return worst(.white, on: samples) >= worst(.black, on: samples) ? .white : .black
    }

    /// White or black, whichever reads better on the samples.
    public static func plainText(on samples: [SeriesColor]) -> SeriesColor {
        worst(.white, on: samples) >= worst(.black, on: samples) ? .white : .black
    }
}
