import AppKit
import SwiftUI

@main
struct Fff3App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("[rgb]", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 640, minHeight: 520)
                // Closing the window frees its views, so nothing redraws while [rgb] lives in the menu bar.
                .onAppear { delegate.windowShown() }
                .onDisappear { delegate.windowClosed() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarMenu(model: delegate.model, delegate: delegate)
        } label: {
            MenuBarIcon(delegate: delegate)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Always on screen, so it holds the action that reopens the window from AppKit code.
private struct MenuBarIcon: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "lightbulb.fill")
            .onAppear { delegate.openMain = { openWindow(id: "main") } }
    }
}

/// A plain menu: it is built only when opened and reads nothing that changes often.
private struct MenuBarMenu: View {
    let model: AppModel
    let delegate: AppDelegate

    var body: some View {
        Button("Open [rgb]") { delegate.showWindow() }
        Divider()
        Text(strips)
        if model.spotify.running {
            if let track = model.spotify.track { Text("\(track.title) – \(track.artist)") }
            Button("Stop album colours") { model.stopSpotify() }
        } else {
            Button("Start album colours") { model.startSpotify() }
                .disabled(!model.spotify.canStart || model.targetIds.isEmpty)
        }
        if model.musicRunning {
            Button("Stop music sync") { model.stopMusic() }
        }
        Divider()
        Button("Quit [rgb]") { delegate.quit() }
            .keyboardShortcut("q")
    }

    private var strips: String {
        let connected = model.devices.filter { model.connection[$0.id] == .connected }.count
        return "\(connected) of \(model.devices.count) strip\(model.devices.count == 1 ? "" : "s") connected"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var openMain: (() -> Void)?
    private var quitting = false

    // The window closing leaves [rgb] in the menu bar, still driving the strips.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd-Q hides to the menu bar; Quit there, logging out or shutting down really quits.
        if quitting || Self.systemIsEndingSession() { return .terminateNow }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
        windowClosed()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the music and free each strip's single connection for the phone.
        model.shutdown()
    }

    func quit() {
        quitting = true
        NSApp.terminate(nil)
    }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
        NSApp.activate()
    }

    func windowShown() {
        NSApp.setActivationPolicy(.regular)
    }

    func windowClosed() {
        // No Dock icon while only the menu bar item is left.
        NSApp.setActivationPolicy(.accessory)
    }

    private static func systemIsEndingSession() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }
}
