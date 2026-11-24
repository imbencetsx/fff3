import AppKit
import Foundation
import Observation
import Fff3Core

/// Where the album cover comes from.
enum AlbumSource: String, CaseIterable, Sendable {
    /// The Spotify Web API: follows any device signed into the account, checks every 5 seconds.
    case spotify
    /// This Mac's Now Playing: any app, no sign-in, no network, changes arrive at once.
    case nowPlaying
}

/// The song shown on the page, from either source.
struct PlayingTrack: Equatable, Sendable {
    let title: String
    let artist: String
    var link: URL? = nil
    var app: String? = nil
}

@MainActor
@Observable
final class SpotifyMode {
    var source: AlbumSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "spotify.source")
            error = nil
            message = idleMessage
        }
    }
    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "spotify.clientID") }
    }
    private(set) var connected: Bool
    private(set) var connecting = false
    private(set) var running = false
    private(set) var track: PlayingTrack?
    private(set) var color: Rgb?
    private(set) var coverColor: Rgb?
    private(set) var message = "Connect your Spotify account to follow album colours."
    private(set) var error: String?
    @ObservationIgnored private let api: SpotifyAPI
    @ObservationIgnored private var callback: SpotifyCallbackServer?
    @ObservationIgnored private var authTimeout: Task<Void, Never>?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var pending: (clientID: String, verifier: String, state: String)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sentColor: Rgb?
    @ObservationIgnored private var nowPlaying: NowPlayingSource?
    @ObservationIgnored private var nowPlayingRetry: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingFailures = 0
    @ObservationIgnored private var players: [NowPlayingPlayer] = []
    // Per player: the colour of its newest cover, and which decode is the newest.
    @ObservationIgnored private var covers: [String: Rgb] = [:]
    @ObservationIgnored private var unreadable: Set<String> = []
    @ObservationIgnored private var coverDecodes: [String: Int] = [:]
    @ObservationIgnored private var browsers: Set<String> = []

    private static let fadeFrames = 16
    private static let fadeFrameSeconds = 0.075

    init() {
        let credentials = SpotifyKeychain.load()
        clientID = credentials?.clientID ?? UserDefaults.standard.string(forKey: "spotify.clientID") ?? ""
        connected = credentials != nil
        api = SpotifyAPI(credentials: credentials)
        source = UserDefaults.standard.string(forKey: "spotify.source").flatMap(AlbumSource.init(rawValue:)) ?? .spotify
        message = idleMessage
    }

    var canStart: Bool { source == .nowPlaying || (connected && !connecting) }

    private var idleMessage: String {
        switch source {
        case .nowPlaying: "Play music in an app on this Mac, then start."
        case .spotify where connected: "Connected. Play a song on Spotify, then start."
        case .spotify: "Connect your Spotify account to follow album colours."
        }
    }

    func connect() {
        guard !running, !connecting else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else {
            error = "Enter the 32-character Client ID from your Spotify developer app."
            return
        }
        error = nil
        connecting = true
        let verifier = SpotifyOAuth.randomSecret()
        let state = SpotifyOAuth.randomSecret()
        pending = (id, verifier, state)
        let url = SpotifyOAuth.authorizationURL(clientID: id, verifier: verifier, state: state)
        do {
            callback = try SpotifyCallbackServer(
                onReady: { [weak self] in Task { @MainActor [weak self] in
                    guard let self, self.pending?.state == state else { return }
                    if !NSWorkspace.shared.open(url) { self.authFailed("Could not open your browser. Try connecting again.") }
                } },
                onURL: { [weak self] url in Task { @MainActor [weak self] in self?.finishSignIn(url) } },
                onError: { [weak self] in Task { @MainActor [weak self] in
                    guard self?.pending?.state == state else { return }
                    self?.authFailed("Could not open the local Spotify callback on port 43821. Close any other [rgb] sign-in and try again.")
                } }
            )
            message = "Finish signing in in your browser."
            authTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                self?.authFailed("Spotify sign-in timed out. Connect again.")
            }
        } catch { authFailed("Could not start Spotify sign-in. Local port 43821 may already be in use.") }
    }

    private func finishSignIn(_ url: URL) {
        guard let pending else { return }
        guard let code = SpotifyOAuth.callbackCode(url, state: pending.state) else {
            authFailed("Spotify sign-in was cancelled or the callback was invalid. Connect again.")
            return
        }
        callback?.stop(); callback = nil
        authTimeout?.cancel(); authTimeout = nil
        self.pending = nil
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.signIn(clientID: pending.clientID, code: code, verifier: pending.verifier)
                try Task.checkCancellation()
                connected = true
                connecting = false
                message = "Connected. Play a song on Spotify, then start."
                error = nil
            } catch {
                if !Task.isCancelled { authFailed(error.localizedDescription) }
            }
        }
    }

    private func authFailed(_ message: String) {
        cancelSignIn()
        error = message
    }

    func cancelSignIn() {
        pending = nil
        callback?.stop(); callback = nil
        authTimeout?.cancel(); authTimeout = nil
        authTask?.cancel(); authTask = nil
        connecting = false
        if !running { message = idleMessage }
    }

    func disconnect() async {
        cancelSignIn()
        do {
            try await api.disconnect()
            connected = false
            track = nil; color = nil; coverColor = nil; error = nil
            message = "Disconnected from Spotify."
        } catch { self.error = error.localizedDescription }
    }

    func start(onColor: @escaping @MainActor (Rgb) -> Void, onFailure: @escaping @MainActor () -> Void) {
        guard canStart, !running else { return }
        if source == .nowPlaying, NowPlayingSource.helperURL == nil {
            error = Self.missingHelper
            return
        }
        running = true
        error = nil
        let generation = UUID()
        self.generation = generation
        if source == .nowPlaying {
            message = "Waiting for Now Playing…"
            browsers = NowPlayingFilter.installedBrowsers()
            launchNowPlaying(generation: generation, onColor: onColor)
            return
        }
        message = "Waiting for Spotify…"
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var wait = 5.0
                do {
                    let track = try await api.currentTrack()
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    if let track {
                        let sampled = try await api.color(for: track.artwork)
                        let color = ArtworkColor.vivid(sampled)
                        try Task.checkCancellation()
                        guard self.generation == generation else { return }
                        if self.color != color || self.track == nil { self.fade(to: color, onColor: onColor) }
                        self.track = PlayingTrack(title: track.title, artist: track.artist, link: track.url)
                        self.color = color
                        self.coverColor = sampled
                        message = "Following album colours on Spotify."
                    } else {
                        self.track = nil
                        message = "Paused or no song available. Holding the last colour."
                    }
                    error = nil
                    failures = 0
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if let failure = error as? SpotifyFailure, failure.needsSignIn {
                        connected = false
                        onFailure()
                        // Set after stopping, which clears the previous error.
                        self.error = error.localizedDescription
                        return
                    }
                    self.error = error.localizedDescription
                    if let failure = error as? SpotifyFailure {
                        if let retryAfter = failure.retryAfter { wait = retryAfter }
                        else { failures += 1; wait = min(60, 5 * pow(2, Double(min(failures, 4)))) }
                    } else {
                        failures += 1; wait = min(60, 5 * pow(2, Double(min(failures, 4))))
                    }
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        fadeTask?.cancel(); fadeTask = nil
        nowPlaying?.stop(); nowPlaying = nil
        nowPlayingRetry?.cancel(); nowPlayingRetry = nil
        players = []; covers = [:]; unreadable = []; coverDecodes = [:]
        nowPlayingFailures = 0
        sentColor = nil
        running = false
        error = nil
        track = nil; color = nil; coverColor = nil
        message = source == .spotify && !connected ? "Connect Spotify again to continue." : idleMessage
    }

    private static let missingHelper = "The Now Playing helper is missing from this build. Rebuild [rgb] with build.sh."
    private static let unreadableCover = "Could not read this song's cover. Holding the last colour."

    private func launchNowPlaying(generation: UUID, onColor: @escaping @MainActor (Rgb) -> Void) {
        guard let helper = NowPlayingSource.helperURL else {
            error = Self.missingHelper
            return
        }
        // DispatchQueue.main keeps the helper's events in order; a Task per event would not.
        let deliver: @Sendable (NowPlayingEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { @Sendable in MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.handle(event, generation: generation, onColor: onColor)
            } }
        }
        let exited: @Sendable (String) -> Void = { [weak self] detail in
            DispatchQueue.main.async { @Sendable in MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.nowPlaying = nil
                // Restart with a growing wait, so a helper that cannot start does not spin.
                let wait = min(60, 2 * pow(2, Double(min(self.nowPlayingFailures, 5))))
                self.nowPlayingFailures += 1
                self.error = "Now Playing stopped (\(detail)). Retrying in \(Int(wait)) seconds."
                self.nowPlayingRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.launchNowPlaying(generation: generation, onColor: onColor)
                }
            } }
        }
        do {
            nowPlaying = try NowPlayingSource(helper: helper, onEvent: deliver, onExit: exited)
        } catch {
            exited(error.localizedDescription)
        }
    }

    private func handle(_ event: NowPlayingEvent, generation: UUID, onColor: @escaping @MainActor (Rgb) -> Void) {
        error = nil
        nowPlayingRetry = nil
        // The helper works again, so a later exit restarts it quickly.
        nowPlayingFailures = 0
        players = event.players
        let live = Set(players.map(\.id))
        covers = covers.filter { live.contains($0.key) }
        unreadable.formIntersection(live)
        for player in players {
            // Browser and video covers are never used, so they are not sampled.
            guard let artwork = player.artwork, NowPlayingFilter.skipReason(player, browsers: browsers) == nil else { continue }
            let decode = (coverDecodes[player.id] ?? 0) + 1
            coverDecodes[player.id] = decode
            // Large covers take a few milliseconds to sample; keep that off the main actor.
            Task.detached(priority: .userInitiated) { [weak self] in
                let cover = ArtworkImage.color(artwork)
                await MainActor.run {
                    guard let self, self.generation == generation, self.coverDecodes[player.id] == decode else { return }
                    if let cover { self.covers[player.id] = cover; self.unreadable.remove(player.id) }
                    else { self.covers[player.id] = nil; self.unreadable.insert(player.id) }
                    self.applyNowPlaying(onColor: onColor)
                }
            }
        }
        applyNowPlaying(onColor: onColor)
    }

    /// The player's own name, else its installed app's name, else its bundle ID.
    private func appName(_ player: NowPlayingPlayer) -> String? {
        if !player.app.isEmpty { return player.app }
        guard let id = player.bundle, !id.isEmpty else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Follows the cover of the music that plays; otherwise holds the last colour.
    private func applyNowPlaying(onColor: @escaping @MainActor (Rgb) -> Void) {
        let (player, ignored) = NowPlayingFilter.pick(players, browsers: browsers)
        let note = ignored.map { " \($0)." } ?? ""
        // A cover decoded later, or another player, ends the unreadable cover error.
        if error == Self.unreadableCover { error = nil }
        guard let player else {
            track = nil
            message = (ignored.map { "\($0)." } ?? "Nothing is playing.") + " Holding the last colour."
            return
        }
        track = PlayingTrack(title: player.title, artist: player.artist, app: appName(player))
        guard player.playing else {
            message = "Paused. Holding the last colour." + note
            return
        }
        guard player.hasArtwork else {
            message = "This song has no cover. Holding the last colour." + note
            return
        }
        if unreadable.contains(player.id) {
            error = Self.unreadableCover
            return
        }
        // Until a new cover is sampled, the previous one stays on the strips.
        guard let cover = covers[player.id] else { return }
        let color = ArtworkColor.vivid(cover)
        if self.color != color { fade(to: color, onColor: onColor) }
        self.color = color
        coverColor = cover
        message = "Following album colours from Now Playing." + note
    }

    private func fade(to target: Rgb, onColor: @escaping @MainActor (Rgb) -> Void) {
        fadeTask?.cancel()
        guard let start = sentColor, start != target else {
            sentColor = target
            onColor(target)
            return
        }
        fadeTask = Task { [weak self] in
            for frame in 1...Self.fadeFrames {
                guard !Task.isCancelled else { return }
                let color = start.blended(toward: target, progress: Double(frame) / Double(Self.fadeFrames))
                onColor(color)
                self?.sentColor = color
                if frame < Self.fadeFrames {
                    try? await Task.sleep(for: .seconds(Self.fadeFrameSeconds))
                }
            }
        }
    }
}
