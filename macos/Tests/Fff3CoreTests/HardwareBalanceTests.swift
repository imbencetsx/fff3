import XCTest
@testable import Fff3Core

final class HardwareBalanceTests: XCTestCase {
    func testUncalibratedPinkInheritsTheStripsWhiteBalance() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 3, blue: 3, gamma: 50), for: .white)
        let output = profile.apply(Rgb(0xE67974))
        XCTAssertGreaterThan(output.red, 180)
        XCTAssertLessThan(output.green, 40)
        XCTAssertLessThan(output.blue, 40)
    }

    func testExplicitPinkCalibrationIsNotCorrectedTwice() {
        var profile = ColorCalibration()
        let pink = Rgb(0xE67974)
        let correction = ColorAdjustment(green: 20, blue: 10)
        profile.set(ColorAdjustment(green: 3, blue: 3, gamma: 50), for: .white)
        profile.set(correction, for: pink)
        XCTAssertEqual(profile.apply(pink), correction.apply(pink))
    }

    func testInheritedControlsMatchTheEffectiveHardwareBalance() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 3, blue: 3, gamma: 50), for: .white)
        let pink = Rgb(0xE67974)
        let inherited = profile.adjustment(for: pink)
        XCTAssertLessThan(inherited.blue, 25)
        let before = profile.apply(pink)
        profile.set(inherited, for: pink)
        let after = profile.apply(pink)
        XCTAssertLessThanOrEqual(abs(before.blue - after.blue), 2)
    }
}
