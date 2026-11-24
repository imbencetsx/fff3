import XCTest
@testable import Fff3Core

final class IndependentCalibrationTests: XCTestCase {
    func testWhiteCorrectionLeavesEveryOtherCalibrationColorAlone() {
        var profile = ColorCalibration()
        for color in ColorCalibration.standardColors where color != .white {
            profile.set(ColorAdjustment(), for: color)
        }
        profile.set(ColorAdjustment(blue: 60), for: .white)
        XCTAssertEqual(profile.apply(.white), Rgb(0xFFFF99))
        for color in ColorCalibration.standardColors where color != .white {
            XCTAssertEqual(profile.apply(color), color, color.toHex())
            XCTAssertEqual(profile.adjustment(for: color), ColorAdjustment())
        }
    }

    func testDifferentColorsKeepDifferentSettingsAndResetIndependently() {
        let red = Rgb(0xFF0000), blue = Rgb(0x0000FF)
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(brightness: 50), for: red)
        profile.set(ColorAdjustment(hue: 120), for: blue)
        XCTAssertEqual(profile.apply(red), Rgb(0x800000))
        XCTAssertEqual(profile.apply(blue), Rgb(0xFF0000))
        XCTAssertEqual(profile.apply(.white), .white)
        profile.reset(red)
        XCTAssertEqual(profile.apply(red), red)
        XCTAssertEqual(profile.apply(blue), Rgb(0xFF0000))
    }

    func testCustomColorIsIndependentAndPersists() throws {
        let custom = Rgb(0x937AC1)
        var profile = ColorCalibration()
        let adjustment = ColorAdjustment(red: 70, brightness: 80, gamma: 130, saturation: 120, hue: -15)
        profile.set(adjustment, for: custom)
        let decoded = try JSONDecoder().decode(ColorCalibration.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.apply(custom), adjustment.apply(custom))
        XCTAssertEqual(decoded.colors.filter { $0 == custom }.count, 1)
        XCTAssertEqual(decoded.apply(.white), .white)
        XCTAssertEqual(decoded.apply(Rgb(0xFF0000)), Rgb(0xFF0000))
    }

    func testNearbyColorsBlendWithoutJumpAtAnchor() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(blue: 60), for: .white)
        let white = profile.apply(.white)
        let nearby = profile.apply(Rgb(0xFEFEFE))
        XCTAssertLessThanOrEqual(abs(white.red - nearby.red), 2)
        XCTAssertLessThanOrEqual(abs(white.blue - nearby.blue), 2)
        XCTAssertEqual(profile.apply(.black), .black)
    }

    func testNeutralCustomPointDoesNotChangeOtherColors() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(), for: Rgb(0x937AC1))
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 17) {
                let color = Rgb.of(r, g, 127)
                XCTAssertEqual(profile.apply(color), color)
            }
        }
    }

    func testLegacyProfilePreservesItsOriginalOutputUntilEdited() throws {
        let json = #"{"red":100,"green":90,"blue":60,"brightness":80,"gamma":130,"saturation":120,"hue":15}"#
        let profile = try JSONDecoder().decode(ColorCalibration.self, from: Data(json.utf8))
        let previous = try JSONDecoder().decode(ColorAdjustment.self, from: Data(json.utf8))
        for color in ColorCalibration.standardColors + [Rgb(0x937AC1)] {
            XCTAssertEqual(profile.apply(color), previous.apply(color))
            XCTAssertEqual(profile.adjustment(for: color), previous)
        }
    }
}
