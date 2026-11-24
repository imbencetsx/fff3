import XCTest
@testable import Fff3Core

final class RgbTests: XCTestCase {
    func testBlendKeepsEndpointsAndInterpolatesChannels() {
        let start = Rgb(0x102030)
        let end = Rgb(0xD0A080)

        XCTAssertEqual(start.blended(toward: end, progress: 0), start)
        XCTAssertEqual(start.blended(toward: end, progress: 1), end)
        XCTAssertEqual(start.blended(toward: end, progress: 0.5), Rgb(0x706058))
    }

    func testBlendClampsProgress() {
        let start = Rgb(0x112233)
        let end = Rgb(0xABCDEF)

        XCTAssertEqual(start.blended(toward: end, progress: -1), start)
        XCTAssertEqual(start.blended(toward: end, progress: 2), end)
    }
}
