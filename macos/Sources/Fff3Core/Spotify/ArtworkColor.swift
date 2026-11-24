import Foundation

public enum ArtworkColor {
    /// Pick an actual opaque sRGB pixel from a large, coherent colour region.
    /// Group neighbouring shades so gradients do not lose to tiny flat details.
    public static func dominant(rgba: [UInt8]) -> Rgb? {
        guard rgba.count >= 4, rgba.count.isMultiple(of: 4) else { return nil }
        var all: [Rgb] = []
        var useful: [Rgb] = []
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] == 255 {
            let color = Rgb.of(Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
            all.append(color)
            if max(color.red, color.green, color.blue) > 25 && min(color.red, color.green, color.blue) < 235 {
                useful.append(color)
            }
        }
        guard !all.isEmpty else { return nil }
        // Ignore black/white borders, but do not let a one-pixel logo set the lights.
        let minimumArea = max(1, Int(ceil(Double(all.count) * 0.02)))
        let chromatic = useful.filter { $0.hsv.value >= 0.08 && $0.hsv.saturation >= 0.18 }
        if let family = mainHueFamily(chromatic, minimumArea: minimumArea) {
            let peak = family.map { $0.hsv.value }.max() ?? 0
            let brighter = family.filter { $0.hsv.value >= max(0.3, peak * 0.55) }
            if let selected = representative(brighter, minimumArea: minimumArea)
                ?? representative(family, minimumArea: minimumArea) { return selected }
        }
        let visible = all.filter { $0.hsv.value >= 0.3 }
        return representative(useful, minimumArea: minimumArea)
            ?? representative(visible, minimumArea: minimumArea)
            ?? representative(all, minimumArea: 1)
    }

    /// Keep the cover hue, but give it enough saturation and level to light the room.
    public static func vivid(_ color: Rgb) -> Rgb {
        let hsv = color.hsv
        let colorful = hsv.saturation >= 0.15
        let saturation = colorful ? min(1, hsv.saturation * 1.15) : hsv.saturation
        let value = max(colorful ? 0.9 : 0.65, hsv.value)
        return .fromHsv(hsv.hue, saturation: saturation, value: value)
    }

    private static func mainHueFamily(_ colors: [Rgb], minimumArea: Int) -> [Rgb]? {
        guard colors.count >= minimumArea else { return nil }
        var counts = [Int](repeating: 0, count: 24)
        var lightness = [Double](repeating: 0, count: 24)
        var axisA = lightness, axisB = lightness
        func bin(_ color: Rgb) -> Int { min(23, Int(color.hsv.hue / 15)) }
        for color in colors {
            let index = bin(color), lab = appearance(color)
            counts[index] += 1
            lightness[index] += lab.0; axisA[index] += lab.1; axisB[index] += lab.2
        }
        let population = Double(colors.count)
        let centre = (lightness.reduce(0, +) / population, axisA.reduce(0, +) / population, axisB.reduce(0, +) / population)
        var best: Int?, bestScore = -1.0, hasMajority = false
        for index in 0..<24 where counts[index] > 0 {
            let neighbours = [(index + 23) % 24, index, (index + 1) % 24]
            let count = neighbours.reduce(0) { $0 + counts[$1] }
            guard count >= minimumArea else { continue }
            let majority = Double(count) / population >= 0.75
            if hasMajority && !majority { continue }
            if majority && !hasMajority { bestScore = -1; hasMajority = true }
            let l = neighbours.reduce(0.0) { $0 + lightness[$1] } / Double(count)
            let a = neighbours.reduce(0.0) { $0 + axisA[$1] } / Double(count)
            let b = neighbours.reduce(0.0) { $0 + axisB[$1] } / Double(count)
            let chroma = sqrt(a * a + b * b)
            let dl = l - centre.0, da = a - centre.1, db = b - centre.2
            let contrast = sqrt(dl * dl + da * da + db * db)
            let score = sqrt(Double(count)) * (0.65 + 0.35 * l)
                * (0.7 + 0.5 * min(1, chroma / 0.2)) * (0.85 + 0.4 * min(1, contrast / 0.3))
            if score > bestScore { bestScore = score; best = index }
        }
        guard let best else { return nil }
        let region = Set([(best + 23) % 24, best, (best + 1) % 24])
        return colors.filter { region.contains(bin($0)) }
    }

    /// Oklab separates perceived lightness and chroma when ranking prominent regions.
    private static func appearance(_ color: Rgb) -> (Double, Double, Double) {
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func representative(_ colors: [Rgb], minimumArea: Int) -> Rgb? {
        guard !colors.isEmpty else { return nil }
        var counts = [Int](repeating: 0, count: 512)
        for color in colors { counts[key(color)] += 1 }
        var bestKey: Int?, bestScore = -1.0
        for bin in counts.indices where counts[bin] > 0 {
            var support = 0
            for neighbour in neighbours(bin) { support += counts[neighbour] }
            guard support >= minimumArea else { continue }
            let r = (bin >> 6) * 32 + 16, g = ((bin >> 3) & 7) * 32 + 16, b = (bin & 7) * 32 + 16
            let saturation = Double(max(r, g, b) - min(r, g, b)) / Double(max(r, g, b))
            let score = Double(support) * (1 + 0.6 * saturation)
            if score > bestScore { bestKey = bin; bestScore = score }
        }
        guard let bestKey else { return nil }
        let region = Set(neighbours(bestKey))
        let members = colors.filter { region.contains(key($0)) }
        let count = Double(members.count)
        let r = Double(members.reduce(0) { $0 + $1.red }) / count
        let g = Double(members.reduce(0) { $0 + $1.green }) / count
        let b = Double(members.reduce(0) { $0 + $1.blue }) / count
        func distance(_ color: Rgb) -> Double {
            let dr = Double(color.red) - r, dg = Double(color.green) - g, db = Double(color.blue) - b
            return dr * dr + dg * dg + db * db
        }
        // The mean locates the region's centre; the returned colour is a real pixel.
        return members.min { distance($0) < distance($1) }
    }

    private static func key(_ color: Rgb) -> Int {
        (color.red >> 5) << 6 | (color.green >> 5) << 3 | (color.blue >> 5)
    }

    private static func neighbours(_ key: Int) -> [Int] {
        let r = key >> 6, g = (key >> 3) & 7, b = key & 7
        var result: [Int] = []
        for red in max(0, r - 1)...min(7, r + 1) {
            for green in max(0, g - 1)...min(7, g + 1) {
                for blue in max(0, b - 1)...min(7, b + 1) { result.append(red << 6 | green << 3 | blue) }
            }
        }
        return result
    }
}
