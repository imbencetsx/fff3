import XCTest
@testable import Fff3Core

final class ArtworkColorTests: XCTestCase {
    private func pixels(_ colors: [Rgb]) -> [UInt8] {
        colors.flatMap { [UInt8($0.red), UInt8($0.green), UInt8($0.blue), 255] }
    }

    func testSelectionIsAnActualPixelRatherThanAnAverage() throws {
        let a = Rgb(0xBA735B), b = Rgb(0xC47D65)
        let selected = try XCTUnwrap(ArtworkColor.dominant(rgba: pixels([a, a, b, b])))
        XCTAssertTrue([a, b].contains(selected))
        XCTAssertNotEqual(selected, Rgb(0xBF7860))
    }

    func testLargeGradientWinsOverSmallHighlySaturatedDetail() throws {
        let gradient = (0..<80).map { Rgb.of(90 + $0 / 4, 110 + $0 / 4, 140 + $0 / 4) }
        let logo = Array(repeating: Rgb(0xFF0000), count: 8)
        let selected = try XCTUnwrap(ArtworkColor.dominant(rgba: pixels(gradient + logo)))
        XCTAssertTrue(gradient.contains(selected))
    }

    func testTinyColoredLogoDoesNotDominateNeutralCover() {
        let colors = Array(repeating: Rgb.white, count: 99) + [Rgb(0xFF0000)]
        XCTAssertEqual(ArtworkColor.dominant(rgba: pixels(colors)), .white)
    }

    func testMonochromeCoverPrefersVisibleNeutralPixel() throws {
        let source = Array(repeating: Rgb.black, count: 70) + Array(repeating: Rgb.white, count: 30)
        let selected = try XCTUnwrap(ArtworkColor.dominant(rgba: pixels(source)))
        XCTAssertEqual(selected, .white)
        XCTAssertEqual(ArtworkColor.vivid(selected), .white)
    }

    func testVibrantOutputKeepsHueAndRaisesBrightness() {
        let source = Rgb(0xA87860)
        let enhanced = ArtworkColor.vivid(source)
        XCTAssertGreaterThan(enhanced.hsv.saturation, source.hsv.saturation)
        XCTAssertEqual(enhanced.hsv.hue, source.hsv.hue, accuracy: 1)
        XCTAssertGreaterThanOrEqual(enhanced.hsv.value, 0.89)
        XCTAssertEqual(ArtworkColor.vivid(Rgb(0x787878)).hsv.saturation, 0)
        XCTAssertEqual(ArtworkColor.vivid(Rgb(0xFF0000)), Rgb(0xFF0000))
    }

    func testSemiTransparentPixelsCannotBiasPalette() {
        XCTAssertNil(ArtworkColor.dominant(rgba: [255, 0, 0, 254]))
        XCTAssertEqual(ArtworkColor.dominant(rgba: [255, 0, 0, 254, 20, 100, 200, 255]), Rgb(0x1464C8))
    }

    func testVibrantAccentWinsOverNeutralDarkBackground() {
        let dark = Array(repeating: Rgb(0x202020), count: 90)
        let orange = Rgb(0xE87040)
        let cover = dark + Array(repeating: orange, count: 10)
        XCTAssertEqual(ArtworkColor.dominant(rgba: pixels(cover)), orange)
    }

    func testDarkCoverStillMakesABrightSaturatedLight() {
        let darkBlue = Rgb(0x0C1428)
        let result = ArtworkColor.vivid(darkBlue)
        XCTAssertGreaterThanOrEqual(result.hsv.value, 0.89)
        XCTAssertGreaterThanOrEqual(result.hsv.saturation, darkBlue.hsv.saturation)
        XCTAssertEqual(result.hsv.hue, darkBlue.hsv.hue, accuracy: 1)
    }

    func testBlackAndDarkGreyStayNeutralButVisible() {
        for source in [Rgb.black, Rgb(0x101010), Rgb(0x404040)] {
            let result = ArtworkColor.vivid(source)
            XCTAssertEqual(result.red, result.green)
            XCTAssertEqual(result.green, result.blue)
            XCTAssertGreaterThanOrEqual(result.hsv.value, 0.64)
        }
    }


    func testMutedWarmColourDoesNotBecomeStrongOrange() {
        let source = Rgb(0x645A50)
        let result = ArtworkColor.vivid(source)
        XCTAssertLessThanOrEqual(result.hsv.saturation - source.hsv.saturation, 0.12)
        XCTAssertEqual(result.hsv.hue, source.hsv.hue, accuracy: 1)
        XCTAssertGreaterThanOrEqual(result.hsv.value, 0.89)
    }

    func testDominantDarkBlueKeepsItsHueInsteadOfChoosingOrangeAccent() throws {
        let blue = Rgb(0x182030)
        let orange = Rgb(0xE87040)
        let cover = Array(repeating: blue, count: 85) + Array(repeating: orange, count: 15)
        let selected = try XCTUnwrap(ArtworkColor.dominant(rgba: pixels(cover)))
        XCTAssertEqual(selected, blue)
        XCTAssertEqual(ArtworkColor.vivid(selected).hsv.hue, blue.hsv.hue, accuracy: 1)
        XCTAssertGreaterThanOrEqual(ArtworkColor.vivid(selected).hsv.value, 0.89)
    }


    func testProminentBrightRegionCanBeatALargerMuddyRegion() {
        let background = Rgb(0x323946), gold = Rgb(0xF0B030)
        let cover = Array(repeating: background, count: 60) + Array(repeating: gold, count: 40)
        XCTAssertEqual(ArtworkColor.dominant(rgba: pixels(cover)), gold)
    }

}
