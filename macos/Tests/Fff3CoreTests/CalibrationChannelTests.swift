import XCTest
@testable import Fff3Core

final class CalibrationChannelTests: XCTestCase {
    func testOrangeBlueControlAlsoSuppressesBlueInNearbyOrangeShades() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(blue: 0), for: Rgb(0xFF8000))
        let output = profile.apply(Rgb(0xFF8040))
        XCTAssertLessThan(output.blue, 16)
        XCTAssertEqual(profile.apply(Rgb(0xFF8000)), Rgb(0xFF8000))
    }

    func testCoverOrangeUsesTheSavedOrangeChannelBalance() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(red: 57, green: 7, blue: 0), for: Rgb(0xFF8000))
        let output = profile.apply(Rgb(0xE67634))
        XCTAssertLessThan(output.blue, 12)
        XCTAssertLessThan(output.green, 30)
        XCTAssertGreaterThan(output.red, output.blue)
    }
}
