import SwiftUI
import UniformTypeIdentifiers

struct SettingsTransferControls: View {
    let model: AppModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document: SettingsBackupDocument?
    @State private var pendingImport: SettingsBackup?
    @State private var error: String?
    @State private var showError = false
    @State private var showImport = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Export settings…") {
                    do {
                        document = SettingsBackupDocument(try model.settingsBackup.encoded())
                        exporting = true
                    } catch { report(error) }
                }
                Button("Import settings…") { importing = true }
            }
            Text(notice ?? "Back up strips, all colour calibrations and app settings. Spotify sign-in stays on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "[rgb]-settings") { result in
            switch result {
            case .success: notice = "Settings exported."
            case .failure(let error): report(error)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5_000_000 else { throw BackupError("This settings file is too large.") }
                pendingImport = try SettingsBackup.read(Data(contentsOf: url))
                showImport = true
            } catch { report(error) }
        }
        .confirmationDialog("Import settings for \(pendingImport?.devices.count ?? 0) strips?",
                            isPresented: $showImport, titleVisibility: .visible) {
            Button("Import settings") {
                guard let pendingImport else { return }
                do {
                    try model.importSettings(pendingImport)
                    notice = "Settings imported. Your previous settings were backed up automatically."
                } catch { report(error) }
                self.pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Updates matching strips and adds missing strips. Other strips are kept. Imported app settings replace the current choices. Spotify sign-in is unchanged.")
        }
        .alert("Settings could not be transferred", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "Please try again.") }
    }

    private func report(_ error: Error) {
        self.error = error.localizedDescription
        showError = true
    }
}
