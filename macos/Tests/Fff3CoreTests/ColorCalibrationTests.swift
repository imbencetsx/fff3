import XCTest
@testable import Fff3Core

final class ColorCalibrationTests: XCTestCase {
    func testDefaultPreservesColorExactly() {
        for color in [Rgb.white, .black, Rgb(0xF28A37), Rgb(0x010203)] {
            XCTAssertEqual(ColorAdjustment().apply(color), color)
        }
    }

    func testBlueTintCorrectionAndGrayUseSameBalance() {
        let balance = ColorAdjustment(red: 100, green: 90, blue: 60)
        XCTAssertEqual(balance.apply(.white), Rgb(0xFFE699))
        XCTAssertEqual(balance.apply(Rgb(0x808080)), Rgb(0x80734D))
        XCTAssertEqual(balance.apply(Rgb(0xFF0000)), Rgb(0xFF0000))
    }

    func testHueAndSaturation() {
        XCTAssertEqual(ColorAdjustment(hue: 120).apply(Rgb(0xFF0000)), Rgb(0x00FF00))
        XCTAssertEqual(ColorAdjustment(saturation: 0).apply(Rgb(0xFF0000)), .white)
        XCTAssertEqual(ColorAdjustment(saturation: 200, hue: 90).apply(Rgb(0x808080)), Rgb(0x808080))
    }

    func testGammaChangesMidtonesAndBrightnessLimitsWhite() {
        XCTAssertEqual(ColorAdjustment(gamma: 200).apply(Rgb(0x808080)), Rgb(0x404040))
        XCTAssertEqual(ColorAdjustment(gamma: 50).apply(Rgb(0x808080)), Rgb(0xB5B5B5))
        XCTAssertEqual(ColorAdjustment(brightness: 50).apply(.white), Rgb(0x808080))
        XCTAssertEqual(ColorAdjustment(gamma: 200).apply(.black), .black)
        XCTAssertEqual(ColorAdjustment(gamma: 200).apply(.white), .white)
    }

    func testPreviousWhiteBalanceLoadsWithNewAdjustmentsNeutral() throws {
        let balance = try JSONDecoder().decode(ColorAdjustment.self, from: Data(#"{"red":100,"green":90,"blue":60}"#.utf8))
        XCTAssertEqual(balance, ColorAdjustment(green: 90, blue: 60))
        XCTAssertEqual(balance.apply(.white), Rgb(0xFFE699))
    }

    func testInvalidGainsAreClampedAndPowerIsUnchanged() {
        var balance = ColorAdjustment()
        balance.red = -5
        balance.green = 200
        balance.blue = 50
        XCTAssertEqual(balance.apply(.white), Rgb(0x00FF80))
        XCTAssertEqual(balance.apply(Command.power(false)), .power(false))
        XCTAssertEqual(balance.apply(Command.brightness(30)), .brightness(30))
        XCTAssertEqual(balance.apply(Command.color(.white)), .color(Rgb(0x00FF80)))
    }
}
