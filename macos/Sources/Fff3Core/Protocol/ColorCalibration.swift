import Foundation

/// Per-strip output correction. The saved and displayed colour stays unmodified.
public struct ColorAdjustment: Codable, Hashable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int
    public var brightness: Int
    public var gamma: Int
    public var saturation: Int
    public var hue: Int

    public init(red: Int = 100, green: Int = 100, blue: Int = 100, brightness: Int = 100,
                gamma: Int = 100, saturation: Int = 100, hue: Int = 0) {
        self.red = red.clamped(0, 100)
        self.green = green.clamped(0, 100)
        self.blue = blue.clamped(0, 100)
        self.brightness = brightness.clamped(0, 100)
        self.gamma = gamma.clamped(50, 250)
        self.saturation = saturation.clamped(0, 200)
        self.hue = hue.clamped(-180, 180)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue, brightness, gamma, saturation, hue }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try values.decodeIfPresent(Int.self, forKey: .red) ?? 100,
                  green: try values.decodeIfPresent(Int.self, forKey: .green) ?? 100,
                  blue: try values.decodeIfPresent(Int.self, forKey: .blue) ?? 100,
                  brightness: try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 100,
                  gamma: try values.decodeIfPresent(Int.self, forKey: .gamma) ?? 100,
                  saturation: try values.decodeIfPresent(Int.self, forKey: .saturation) ?? 100,
                  hue: try values.decodeIfPresent(Int.self, forKey: .hue) ?? 0)
    }

    public func apply(_ color: Rgb) -> Rgb {
        var adjusted = color
        if hue != 0 || saturation != 100 {
            let hsv = color.hsv
            adjusted = .fromHsv(hsv.hue + Float(hue.clamped(-180, 180)),
                               saturation: hsv.saturation * Float(saturation.clamped(0, 200)) / 100,
                               value: hsv.value)
        }
        let exponent = Double(gamma.clamped(50, 250)) / 100
        let level = Double(brightness.clamped(0, 100)) / 100
        func channel(_ value: Int, gain: Int) -> Int {
            let balanced = Double(value) * Double(gain.clamped(0, 100)) / 25_500
            return Int((pow(balanced, exponent) * level * 255 + 0.5).rounded(.down))
        }
        return .of(channel(adjusted.red, gain: red), channel(adjusted.green, gain: green), channel(adjusted.blue, gain: blue))
    }

    public func apply(_ command: Command) -> Command {
        if case .color(let color) = command { return .color(apply(color)) }
        return command
    }
}


/// Independent calibration points; nearby colours blend their corrections smoothly.
public struct ColorCalibration: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public let color: Rgb
        public var adjustment: ColorAdjustment
    }

    public static let standardColors: [Rgb] = [
        .white, Rgb(0x808080), Rgb(0x202020), Rgb(0xFF0000), Rgb(0x00FF00),
        Rgb(0x0000FF), Rgb(0xFF8000), Rgb(0xFFFF00), Rgb(0x00FFFF), Rgb(0xFF00FF),
    ]
    private var base: ColorAdjustment
    public private(set) var points: [Point] = []

    public init(red: Int = 100, green: Int = 100, blue: Int = 100, brightness: Int = 100,
                gamma: Int = 100, saturation: Int = 100, hue: Int = 0) {
        base = ColorAdjustment(red: red, green: green, blue: blue, brightness: brightness,
                               gamma: gamma, saturation: saturation, hue: hue)
    }

    private enum CodingKeys: String, CodingKey { case base, points }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Earlier profiles had a single adjustment at the top level.
        base = try values.decodeIfPresent(ColorAdjustment.self, forKey: .base) ?? ColorAdjustment(from: decoder)
        points = try values.decodeIfPresent([Point].self, forKey: .points) ?? []
    }

    public var colors: [Rgb] {
        Self.standardColors + points.map(\.color).filter { !Self.standardColors.contains($0) }
    }

    public func adjustment(for color: Rgb) -> ColorAdjustment {
        if let saved = points.first(where: { $0.color == color }) { return saved.adjustment }
        if isNeutral(color), color.red > 0, points.contains(where: { isNeutral($0.color) }) {
            let output = neutralOutput(color)
            let peak = max(output.red, output.green, output.blue)
            guard peak > 0 else { return ColorAdjustment(brightness: 0) }
            if peak <= color.red {
                return ColorAdjustment(red: Int((Double(output.red) * 100 / Double(peak)).rounded()),
                                       green: Int((Double(output.green) * 100 / Double(peak)).rounded()),
                                       blue: Int((Double(output.blue) * 100 / Double(peak)).rounded()),
                                       brightness: Int((Double(peak) * 100 / Double(color.red)).rounded()))
            }
        }
        return inheritedAdjustment
    }

    public mutating func set(_ adjustment: ColorAdjustment, for color: Rgb) {
        points.removeAll { $0.color == color }
        points.append(Point(color: color, adjustment: adjustment))
        points.sort { $0.color.packed < $1.color.packed }
    }

    public mutating func reset(_ color: Rgb) {
        points.removeAll { $0.color == color }
        if !Self.standardColors.contains(color) { set(inheritedAdjustment, for: color) }
    }

    public func apply(_ color: Rgb) -> Rgb {
        guard !points.isEmpty else { return base.apply(color) }
        if isNeutral(color) { return neutralOutput(color) }
        let anchors = colors + [.black]
        let original = neutralAwareBase(color)
        let chromaWeight = smoothstep(Double(color.hsv.saturation) / 0.15)
        var total = 0.0, r = 0.0, g = 0.0, b = 0.0
        for anchor in anchors {
            let adjustment = points.first(where: { $0.color == anchor })?.adjustment ?? inheritedAdjustment
            if color == anchor { return adjustment.apply(color) }
            let dr = Double(color.red - anchor.red), dg = Double(color.green - anchor.green), db = Double(color.blue - anchor.blue)
            let distance = dr * dr + dg * dg + db * db
            let weight = (isNeutral(anchor) ? 1 : chromaWeight) / (distance * distance)
            total += weight
            guard !isNeutral(anchor) else { continue }
            // Blend correction functions, so a zero channel also suppresses it in nearby shades.
            let output = adjustment.apply(color), baseline = hardwareBase(color)
            r += Double(output.red - baseline.red) * weight
            g += Double(output.green - baseline.green) * weight
            b += Double(output.blue - baseline.blue) * weight
        }
        return .of(Int((Double(original.red) + r / total).rounded()),
                   Int((Double(original.green) + g / total).rounded()),
                   Int((Double(original.blue) + b / total).rounded()))
    }

    private var inheritedAdjustment: ColorAdjustment {
        guard let white = points.first(where: { $0.color == .white })?.adjustment else { return base }
        let corrected = white.apply(.white), original = base.apply(.white)
        var inherited = base
        let exponent = 100 / Double(base.gamma.clamped(50, 250))
        func gain(_ gain: Int, _ corrected: Int, _ original: Int) -> Int {
            guard original > 0 else { return gain }
            return Int((Double(gain) * pow(Double(corrected) / Double(original), exponent)).rounded()).clamped(0, 100)
        }
        inherited.red = gain(base.red, corrected.red, original.red)
        inherited.green = gain(base.green, corrected.green, original.green)
        inherited.blue = gain(base.blue, corrected.blue, original.blue)
        return inherited
    }

    private func hardwareBase(_ color: Rgb) -> Rgb { inheritedAdjustment.apply(color) }

    private func smoothstep(_ value: Double) -> Double {
        let t = value.clamped(0, 1)
        return t * t * (3 - 2 * t)
    }

    private func neutralAwareBase(_ color: Rgb) -> Rgb {
        let original = hardwareBase(color)
        let hsv = color.hsv
        let strength = 1 - smoothstep(Double(hsv.saturation) / 0.2)
        guard strength > 0 else { return original }
        let level = max(color.red, color.green, color.blue)
        let grey = Rgb.of(level, level, level)
        let target = neutralOutput(grey), baseline = hardwareBase(grey)
        func channel(_ original: Int, _ target: Int, _ baseline: Int) -> Int {
            Int((Double(original) + strength * Double(target - baseline)).rounded())
        }
        return .of(channel(original.red, target.red, baseline.red),
                   channel(original.green, target.green, baseline.green), channel(original.blue, target.blue, baseline.blue))
    }

    private func isNeutral(_ color: Rgb) -> Bool {
        color.red == color.green && color.green == color.blue
    }

    private func neutralOutput(_ color: Rgb) -> Rgb {
        guard color.red > 0 else { return .black }
        if let saved = points.first(where: { $0.color == color }) { return saved.adjustment.apply(color) }
        let anchors = colors.filter { isNeutral($0) && $0.red > 0 }.sorted { $0.red < $1.red }
        let lower = anchors.last(where: { $0.red <= color.red }) ?? anchors[0]
        let upper = anchors.first(where: { $0.red >= color.red }) ?? anchors[anchors.count - 1]
        func correction(_ anchor: Rgb) -> (Double, Double, Double) {
            let saved = points.first(where: { $0.color == anchor })?.adjustment ?? inheritedAdjustment
            let output = saved.apply(anchor), baseline = hardwareBase(anchor)
            let scale = Double(anchor.red)
            return (Double(output.red - baseline.red) / scale,
                    Double(output.green - baseline.green) / scale,
                    Double(output.blue - baseline.blue) / scale)
        }
        let a = correction(lower), b = correction(upper)
        let t = lower == upper ? 0 : Double(color.red - lower.red) / Double(upper.red - lower.red)
        let original = hardwareBase(color), level = Double(color.red)
        func channel(_ original: Int, _ a: Double, _ b: Double) -> Int {
            Int((Double(original) + level * (a + (b - a) * t)).rounded())
        }
        return .of(channel(original.red, a.0, b.0), channel(original.green, a.1, b.1), channel(original.blue, a.2, b.2))
    }

    public func apply(_ command: Command) -> Command {
        if case .color(let color) = command { return .color(apply(color)) }
        return command
    }
}
