import SwiftUI
import Fff3Core

struct SpotifyPage: View {
    @Bindable var model: AppModel
    let theme: Theme
    let accent: Color
    @State private var showingCalibration = false
    @State private var calibrationColor = Rgb.white
    @State private var resumeAfterCalibration = false
    private var spotify: SpotifyMode { model.spotify }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Album colours").font(.title2.weight(.semibold))
                Text("Set your strips to a colour from the current song's album cover.")
                    .font(.system(size: 12)).foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Cover from", selection: Binding(get: { spotify.source }, set: { spotify.source = $0 })) {
                        Text("Spotify account").tag(AlbumSource.spotify)
                        Text("This Mac's Now Playing").tag(AlbumSource.nowPlaying)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    .disabled(spotify.running)
                    Text(spotify.source == .spotify
                         ? "Follows playback on any device signed into your Spotify account. Needs your own Spotify app and checks every 5 seconds."
                         : "Follows music apps on this Mac, such as Spotify, Music or a player in your terminal. Browsers, videos and podcasts are ignored. No sign-in, and colour changes as soon as the song does.")
                        .font(.system(size: 11)).foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    QuietButton(title: spotify.running ? "Stop" : "Start", systemImage: spotify.running ? "stop.fill" : "play.fill",
                                theme: theme, accent: accent, prominent: true, onAccent: theme.onAccent(model.accent)) {
                        if spotify.running { model.stopSpotify() } else { model.startSpotify() }
                    }
                    .disabled(!spotify.running && (!spotify.canStart || model.targetIds.isEmpty))
                    Text(spotify.running ? connectionStatus : "Uses the strips selected in the sidebar.")
                        .font(.system(size: 12)).foregroundStyle(theme.dim)
                }
                Text(spotify.message).font(.system(size: 12)).accessibilityAddTraits(.updatesFrequently)
                if let error = spotify.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let track = spotify.track {
                    HStack(spacing: 12) {
                        if let color = spotify.color {
                            RoundedRectangle(cornerRadius: 8).fill(Color(color)).frame(width: 48, height: 48)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
                                .accessibilityLabel("Light colour \(color.toHex())")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.system(size: 14, weight: .semibold))
                            Text(track.artist).font(.system(size: 12)).foregroundStyle(theme.dim)
                            if let link = track.link {
                                Link("Open in Spotify", destination: link).font(.system(size: 12))
                            } else if let app = track.app {
                                Text("Playing in \(app)").font(.system(size: 11)).foregroundStyle(theme.dim)
                            }
                        }
                        Spacer()
                        if let color = spotify.color {
                            VStack(alignment: .trailing, spacing: 4) {
                                if let cover = spotify.coverColor {
                                    Text("Cover \(cover.toHex())")
                                }
                                Text("Lights \(color.toHex())")
                            }
                            .font(.system(size: 11).monospaced()).foregroundStyle(theme.dim)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.surface.opacity(0.55)))
                    Button("Calibrate this colour…") {
                        calibrationColor = spotify.color ?? .white
                        resumeAfterCalibration = spotify.running
                        showingCalibration = true
                    }
                }
                Text("Follows the cover’s main colour family, then brightens a real sampled colour with a small saturation boost. Muted colours stay muted. Changes between songs fade over about a second. Pausing holds the last colour. Stop restores your previous lights. Starting audio sync or changing the selected strips stops this mode.")
                    .font(.system(size: 11)).foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                if spotify.source == .spotify {
                    connection
                    Text("Spotify mode uses the internet for sign-in, current-track details and album artwork. Tokens stay in macOS Keychain. Audio is never captured or uploaded by this mode.")
                        .font(.system(size: 11)).foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Now Playing reads the song's title, artist and cover from macOS. macOS only shares them with its own programs, so [rgb] runs a small helper inside the system Perl to read them. Nothing leaves this Mac, and audio is never captured.")
                        .font(.system(size: 11)).foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingCalibration, onDismiss: {
            model.endColorCalibration()
            if resumeAfterCalibration { model.startSpotify() }
        }) {
            ColorCalibrationSheet(model: model, initialColor: calibrationColor)
        }
    }

    private var connectionStatus: String {
        let count = model.targetIds.filter { model.connection[$0] == .connected }.count
        if count == 0 { return "Waiting for Bluetooth connection…" }
        if count < model.targetIds.count { return "Connected to \(count) of \(model.targetIds.count) strips" }
        return "Following on \(count) strip\(count == 1 ? "" : "s")"
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Spotify app").font(.system(size: 13, weight: .semibold))
            Text("1. Create an app in the Spotify developer dashboard and select Web API.\n2. Add this exact redirect URI in the app settings.\n3. Paste the app's Client ID below and connect. No client secret is needed.")
                .font(.system(size: 12)).foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Link("Open Spotify developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .font(.system(size: 12))
            Text(SpotifyOAuth.redirectURI).font(.system(size: 12).monospaced()).textSelection(.enabled)
            TextField("Client ID", text: Binding(get: { spotify.clientID }, set: { spotify.clientID = $0 }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Spotify Client ID")
                .disabled(spotify.connected || spotify.connecting || spotify.running)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if spotify.connecting {
                    ProgressView().controlSize(.small)
                    Button("Cancel sign-in") { spotify.cancelSignIn() }
                } else if spotify.connected {
                    Label("Connected to Spotify", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(theme.ok)
                    Button("Disconnect") {
                        model.stopSpotify()
                        Task { await spotify.disconnect() }
                    }
                } else {
                    QuietButton(title: "Connect Spotify", theme: theme, accent: accent) { spotify.connect() }
                }
            }
            Text("Spotify's development mode requires an eligible Premium app owner and allows a limited set of users. Add other accounts under User Management in the dashboard. A 403 error usually means account access needs checking.")
                .font(.system(size: 11)).foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
