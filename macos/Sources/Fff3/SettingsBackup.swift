import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Fff3Core

struct SettingsBackup: Codable, Sendable {
    let format: String
    let version: Int
    let devices: [KnownDevice]
    let states: [String: LedState]
    let settings: Settings

    init(_ data: AppData) {
        format = "fff3-macos-settings"
        version = 1
        devices = data.devices
        states = data.states
        settings = data.settings
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func read(_ data: Data) throws -> SettingsBackup {
        guard data.count <= 5_000_000 else { throw BackupError("This settings file is too large.") }
        let backup: SettingsBackup
        do { backup = try JSONDecoder().decode(SettingsBackup.self, from: data) }
        catch { throw BackupError("This is not a complete [rgb] settings export, or the file is damaged.") }
        guard backup.format == "fff3-macos-settings", backup.version == 1 else {
            throw BackupError("This settings export is from an unsupported format or version.")
        }
        guard Set(backup.devices.map(\.id)).count == backup.devices.count else {
            throw BackupError("The settings file contains duplicate strips.")
        }
        for device in backup.devices {
            if let profile = device.colorCalibration {
                guard profile.colors.allSatisfy({ (0...0xFFFFFF).contains($0.packed) }),
                      Set(profile.points.map(\.color)).count == profile.points.count else {
                    throw BackupError("The settings file contains an invalid colour calibration.")
                }
            }
        }
        guard backup.states.values.allSatisfy({ state in
            (state.color.map { (0...0xFFFFFF).contains($0.packed) } ?? true)
                && (state.brightness.map { (0...100).contains($0) } ?? true)
                && (state.speed.map { (0...100).contains($0) } ?? true)
        }), backup.settings.musicSensitivity.isFinite,
              (0...1).contains(backup.settings.musicSensitivity) else {
            throw BackupError("The settings file contains invalid light settings.")
        }
        return backup
    }

    func merged(into current: AppData) -> AppData {
        var result = current
        for device in devices {
            if let index = result.devices.firstIndex(where: { $0.id == device.id }) { result.devices[index] = device }
            else { result.devices.append(device) }
            if let state = states[device.id.uuidString] { result.states[device.id.uuidString] = state }
        }
        result.settings = settings
        return result
    }
}

struct BackupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw BackupError("Could not read the settings file.") }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
