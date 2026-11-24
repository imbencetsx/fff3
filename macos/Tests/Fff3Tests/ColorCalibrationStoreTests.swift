import XCTest
import Fff3Core
@testable import Fff3

final class ColorCalibrationStoreTests: XCTestCase {
    func testOldStripStillDecodesWithoutCalibration() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","advertisedName":"ELK-BLEDOM","family":"DOM","label":"Desk"}"#
        let strip = try JSONDecoder().decode(KnownDevice.self, from: Data(json.utf8))
        XCTAssertEqual(strip.label, "Desk")
        XCTAssertNil(strip.colorCalibration)
    }

    func testBalanceBelongsOnlyToOneStripAndRoundTrips() throws {
        var data = AppData()
        let first = UUID(), second = UUID()
        data.devices = [
            KnownDevice(id: first, advertisedName: "ELK-BLEDOM", family: .DOM, colorCalibration: ColorCalibration(blue: 65, brightness: 80, gamma: 130, saturation: 85, hue: -15)),
            KnownDevice(id: second, advertisedName: "ELK-BLEDOM", family: .DOM),
        ]
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.devices.count, 2)
        XCTAssertEqual(decoded.devices[0].colorCalibration, ColorCalibration(blue: 65, brightness: 80, gamma: 130, saturation: 85, hue: -15))
        XCTAssertNil(decoded.devices[1].colorCalibration)
        XCTAssertEqual(decoded.devices[0].id, first)
        XCTAssertEqual(decoded.devices[1].id, second)
    }

    func testIndependentColorsSurviveSavingStripData() throws {
        var data = AppData()
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(blue: 60), for: .white)
        profile.set(ColorAdjustment(brightness: 75), for: Rgb(0xFF0000))
        data.devices = [KnownDevice(id: UUID(), advertisedName: "ELK-BLEDOM", family: .DOM, colorCalibration: profile)]
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        let saved = try XCTUnwrap(decoded.devices.first?.colorCalibration)
        XCTAssertEqual(saved.adjustment(for: .white).blue, 60)
        XCTAssertEqual(saved.adjustment(for: Rgb(0xFF0000)).brightness, 75)
        XCTAssertEqual(saved.adjustment(for: Rgb(0x0000FF)).blue, 60)
        XCTAssertNil(saved.points.first(where: { $0.color == Rgb(0x0000FF) }))
    }

}
