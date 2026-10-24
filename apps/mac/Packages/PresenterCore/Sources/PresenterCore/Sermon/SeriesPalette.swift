import Foundation

/// The main colors of a piece of art, found with k-means over its pixels.
/// Used when Claude can't read the art (no key, no network), so a series
/// made from a photo still takes its colors from the photo.
public enum SeriesPalette {
    public struct Swatch: Equatable, Sendable {
        public var color: SeriesColor
        /// How much of the image is this color, 0 to 1.
        public var share: Double
    }

    /// Up to `count` swatches, largest first. Deterministic: the same pixels
    /// always give the same palette, so Try Again offline is predictable
    /// and the tests can pin it.
    public static func extract(_ pixels: [SeriesColor], count: Int = 6, iterations: Int = 12) -> [Swatch] {
        guard !pixels.isEmpty, count > 0 else { return [] }
        var centers = seeds(pixels, count: min(count, pixels.count))
        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<iterations {
            var changed = false
            for (index, pixel) in pixels.enumerated() {
                let nearest = nearestCenter(pixel, centers)
                if nearest != assignment[index] {
                    assignment[index] = nearest
                    changed = true
                }
            }
            var sums = [(r: Double, g: Double, b: Double, n: Int)](repeating: (0, 0, 0, 0), count: centers.count)
            for (index, pixel) in pixels.enumerated() {
                let cluster = assignment[index]
                sums[cluster].r += pixel.red
                sums[cluster].g += pixel.green
                sums[cluster].b += pixel.blue
                sums[cluster].n += 1
            }
            for cluster in centers.indices where sums[cluster].n > 0 {
                let n = Double(sums[cluster].n)
                centers[cluster] = SeriesColor(red: sums[cluster].r / n, green: sums[cluster].g / n, blue: sums[cluster].b / n)
            }
            if !changed { break }
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for cluster in assignment { counts[cluster] += 1 }
        let total = Double(pixels.count)
        // Clusters that ended up near-identical are folded together.
        var swatches: [Swatch] = []
        for cluster in centers.indices where counts[cluster] > 0 {
            let swatch = Swatch(color: centers[cluster], share: Double(counts[cluster]) / total)
            if let same = swatches.firstIndex(where: { $0.color.distanceSquared(to: swatch.color) < 0.004 }) {
                swatches[same].share += swatch.share
            } else {
                swatches.append(swatch)
            }
        }
        return swatches.sorted { $0.share != $1.share ? $0.share > $1.share : $0.color.luminance > $1.color.luminance }
    }

    /// The color that best stands for the series: the most vivid swatch
    /// that is more than a speck, else the largest. `skip` steps through
    /// the other candidates, for Try Again.
    public static func accent(of swatches: [Swatch], skip: Int = 0) -> SeriesColor? {
        let candidates = swatches.filter { $0.share >= 0.02 }
            .sorted { vividness($0) > vividness($1) }
        guard !candidates.isEmpty else { return swatches.first?.color }
        return candidates[skip % candidates.count].color
    }

    private static func vividness(_ swatch: Swatch) -> Double {
        // Saturated and bright enough to see, with a nod to how much of the
        // art it covers.
        swatch.color.saturation * (0.4 + swatch.color.brightness) * (0.6 + min(swatch.share, 0.4))
    }

    /// k-means++ style seeding, made deterministic: start from the pixel
    /// nearest the image's average, then repeatedly take the pixel farthest
    /// from every center so far.
    private static func seeds(_ pixels: [SeriesColor], count: Int) -> [SeriesColor] {
        let n = Double(pixels.count)
        let mean = SeriesColor(red: pixels.reduce(0) { $0 + $1.red } / n,
                               green: pixels.reduce(0) { $0 + $1.green } / n,
                               blue: pixels.reduce(0) { $0 + $1.blue } / n)
        var centers = [pixels.min { $0.distanceSquared(to: mean) < $1.distanceSquared(to: mean) } ?? mean]
        var nearest = pixels.map { $0.distanceSquared(to: centers[0]) }
        while centers.count < count {
            guard let far = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[far] > 0 else { break }
            let center = pixels[far]
            centers.append(center)
            for index in pixels.indices {
                nearest[index] = min(nearest[index], pixels[index].distanceSquared(to: center))
            }
        }
        return centers
    }

    private static func nearestCenter(_ pixel: SeriesColor, _ centers: [SeriesColor]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, center) in centers.enumerated() {
            let distance = pixel.distanceSquared(to: center)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
