import XCTest
import Fff3Core
@testable import Fff3

final class SettingsBackupTests: XCTestCase {
    func testExportRoundTripsAllColourOverrides() throws {
        var data = AppData()
        let id = UUID()
        var profile = ColorCalibration()
        profile.set(ColorAdjustment(green: 3, blue: 3, gamma: 50), for: .white)
        profile.set(ColorAdjustment(green: 25, blue: 10), for: Rgb(0xE67974))
        data.devices = [KnownDevice(id: id, advertisedName: "ELK-BLEDOB", family: .DOB, label: "Desk", colorCalibration: profile)]
        data.states[id.uuidString] = LedState(power: true, color: Rgb(0xE67974), brightness: 80)
        data.settings.musicSensitivity = 0.7
        let decoded = try SettingsBackup.read(SettingsBackup(data).encoded())
        XCTAssertEqual(decoded.devices, data.devices)
        XCTAssertEqual(decoded.states, data.states)
        XCTAssertEqual(decoded.settings, data.settings)
        let text = String(decoding: try decoded.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("accessToken"))
        XCTAssertFalse(text.contains("refreshToken"))
    }

    func testImportMergesWithoutRemovingOtherStrips() {
        var current = AppData(), imported = AppData()
        let matching = UUID(), kept = UUID(), added = UUID()
        current.devices = [KnownDevice(id: matching, advertisedName: "ELK-BLEDOB", family: .DOB, label: "Before"),
                           KnownDevice(id: kept, advertisedName: "ELK-BLEDOM", family: .DOM)]
        imported.devices = [KnownDevice(id: matching, advertisedName: "ELK-BLEDOB", family: .DOB, label: "Restored", colorCalibration: ColorCalibration(blue: 50)),
                            KnownDevice(id: added, advertisedName: "ELK-BLEDOM", family: .DOM)]
        let result = SettingsBackup(imported).merged(into: current)
        XCTAssertEqual(result.devices.count, 3)
        XCTAssertEqual(result.devices.first(where: { $0.id == matching })?.label, "Restored")
        XCTAssertEqual(result.devices.first(where: { $0.id == matching })?.colorCalibration, ColorCalibration(blue: 50))
        XCTAssertNotNil(result.devices.first(where: { $0.id == kept }))
        XCTAssertNotNil(result.devices.first(where: { $0.id == added }))
    }

    func testIncompleteFileIsRejectedInsteadOfDefaultingAwaySettings() {
        XCTAssertThrowsError(try SettingsBackup.read(Data(#"{"devices":[],"states":{},"settings":{}}"#.utf8)))
    }

    func testFutureVersionAndDuplicateStripsAreRejected() throws {
        var data = AppData()
        let strip = KnownDevice(id: UUID(), advertisedName: "ELK-BLEDOM", family: .DOM)
        data.devices = [strip, strip]
        XCTAssertThrowsError(try SettingsBackup.read(SettingsBackup(data).encoded()))
        let valid = try SettingsBackup(AppData()).encoded()
        let future = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        XCTAssertThrowsError(try SettingsBackup.read(Data(future.utf8)))
    }
}
