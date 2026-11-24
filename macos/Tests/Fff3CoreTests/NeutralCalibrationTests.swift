import XCTest
@testable import Fff3Core

final class NeutralCalibrationTests: XCTestCase {
    func testColourEditsCannotTintUncalibratedGreys() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(hue: 120), for: Rgb(0x0000FF))
        for level in 1..<255 {
            let grey = Rgb.of(level, level, level)
            XCTAssertEqual(profile.apply(grey), grey, "Grey level \(level)")
        }
    }

    func testSavedGreyBalanceSurvivesChangesToOtherColours() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 35, blue: 34, brightness: 91, gamma: 99), for: Rgb(0x202020))
        profile.set(ColorAdjustment(green: 23, blue: 25, brightness: 34), for: Rgb(0x808080))
        profile.set(ColorAdjustment(green: 18, blue: 17), for: .white)
        let before = (1..<255).map { profile.apply(.of($0, $0, $0)) }
        profile.set(ColorAdjustment(hue: 120), for: Rgb(0x0000FF))
        profile.set(ColorAdjustment(green: 11, blue: 4), for: Rgb(0xFF8000))
        for level in 1..<255 {
            XCTAssertEqual(profile.apply(.of(level, level, level)), before[level - 1])
        }
        XCTAssertEqual(profile.apply(Rgb(0x202020)), Rgb(0x1E0B0A))
        XCTAssertEqual(profile.apply(.white), Rgb(0xFF2E2B))
    }

    func testAlmostGreyKeepsTheSameBalanceAsGrey() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 35, blue: 34, brightness: 91), for: Rgb(0x202020))
        profile.set(ColorAdjustment(green: 23, blue: 25, brightness: 34), for: Rgb(0x808080))
        profile.set(ColorAdjustment(green: 11, blue: 4), for: Rgb(0xFF8000))
        let grey = profile.apply(Rgb(0x404040))
        let almostGrey = profile.apply(Rgb(0x404041))
        XCTAssertLessThanOrEqual(abs(grey.red - almostGrey.red), 2)
        XCTAssertLessThanOrEqual(abs(grey.green - almostGrey.green), 2)
        XCTAssertLessThanOrEqual(abs(grey.blue - almostGrey.blue), 2)
    }


    func testVeryDarkAdjustmentStartsFromSavedBalanceAndDoesNotChangeWhite() {
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 35, blue: 34, brightness: 91), for: Rgb(0x202020))
        profile.set(ColorAdjustment(green: 18, blue: 17), for: .white)
        let veryDark = Rgb(0x101010)
        let before = profile.apply(veryDark)
        let inherited = profile.adjustment(for: veryDark)
        XCTAssertLessThan(inherited.blue, inherited.red)
        let white = profile.apply(.white)
        profile.set(inherited, for: veryDark)
        let after = profile.apply(veryDark)
        XCTAssertLessThanOrEqual(abs(before.red - after.red), 1)
        XCTAssertLessThanOrEqual(abs(before.green - after.green), 1)
        XCTAssertLessThanOrEqual(abs(before.blue - after.blue), 1)
        var tuned = inherited
        tuned.red = 80
        profile.set(tuned, for: veryDark)
        XCTAssertEqual(profile.apply(.white), white)
    }

}
