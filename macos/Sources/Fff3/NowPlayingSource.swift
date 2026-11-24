import AppKit

/// One player in Now Playing, as the helper prints it.
struct NowPlayingPlayer: Decodable, Equatable, Sendable {
    /// MediaRemote's description of the player path: stable while the player runs.
    let id: String
    let title: String
    let artist: String
    let album: String
    let app: String
    /// Bundle IDs of the player and, for web content, of the browser that runs it.
    var bundle: String? = nil
    var parent: String? = nil
    /// MediaRemote's media type, such as kMRMediaRemoteNowPlayingInfoTypeAudio, and "audio" or "video".
    var mediaType: String? = nil
    var strictMediaType: String? = nil
    /// The player macOS shows in Control Centre. Others can still be playing.
    var active = false
    let playing: Bool
    let hasArtwork: Bool
    /// Sent only when the cover changes, so each song's image crosses the pipe once.
    var artwork: Data? = nil
}

/// Every player at one moment, sent whenever any of them changes.
struct NowPlayingEvent: Decodable, Equatable, Sendable {
    let players: [NowPlayingPlayer]
}

/// Keeps album colours to music: browsers, video and podcasts do not change the lights.
enum NowPlayingFilter {
    // Matched with their sub-IDs, so helpers and beta builds count too.
    static let browsers = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.WebKit", "com.google.Chrome",
                           "org.chromium", "org.mozilla", "company.thebrowser", "com.brave.Browser", "com.microsoft.edgemac",
                           "com.operasoftware", "com.vivaldi", "com.kagi.kagimacOS", "app.zen-browser", "net.imput.helium"]
    static let notMusic = ["com.apple.TV", "com.apple.podcasts"]

    /// Apps that open web links: catches browsers missing from the list above.
    @MainActor static func installedBrowsers() -> Set<String> {
        Set(NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// The music player to follow: a playing one first, then the one Control Centre shows.
    /// So a video starting in a browser does not take the lights from music still playing.
    static func pick(_ players: [NowPlayingPlayer], browsers: Set<String>) -> (player: NowPlayingPlayer?, ignored: String?) {
        let named = players.filter { !$0.title.isEmpty }
        let music = named.filter { skipReason($0, browsers: browsers) == nil }
        let playing = music.filter(\.playing)
        let player = playing.first(where: \.active) ?? playing.first ?? music.first(where: \.active) ?? music.first
        // Name what is being ignored only when it is playing or was the only thing there.
        let others = named.filter { $0.id != player?.id && ($0.playing || player == nil) }
            .sorted { $0.playing && !$1.playing }
        return (player, others.lazy.compactMap { skipReason($0, browsers: browsers) }.first)
    }

    /// Why this player must not change the lights, or nil when it is music.
    static func skipReason(_ event: NowPlayingPlayer, browsers installed: Set<String>) -> String? {
        let ids = [event.bundle, event.parent].compactMap { $0 }.filter { !$0.isEmpty }
        func matches(_ list: [String]) -> Bool {
            ids.contains { id in list.contains { id == $0 || id.hasPrefix($0 + ".") } }
        }
        if matches(browsers) || ids.contains(where: installed.contains) { return "Browsers don't change the lights" }
        let types = [event.mediaType, event.strictMediaType].compactMap { $0?.lowercased() }
        if types.contains(where: { $0.contains("video") }) { return "Videos don't change the lights" }
        if matches(notMusic) || types.contains(where: { $0.contains("podcast") }) { return "Only music changes the lights" }
        return nil
    }
}

/// Splits the helper's output into events. A line can arrive in several reads.
struct NowPlayingLineReader {
    private var buffer = Data()
    private static let maxLine = 20_000_000

    mutating func append(_ data: Data) -> [NowPlayingEvent] {
        buffer.append(data)
        var events: [NowPlayingEvent] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let event = try? JSONDecoder().decode(NowPlayingEvent.self, from: line) { events.append(event) }
        }
        if buffer.count > Self.maxLine { buffer = Data() }
        return events
    }
}

/// Runs Helpers/NowPlaying.m inside /usr/bin/perl. macOS answers Now Playing requests only
/// from Apple-signed processes, and the system Perl is one that can load our code.
final class NowPlayingSource: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var stopped = false
    // The end of the helper's stderr, read as it comes so a full pipe never blocks it.
    private var errorTail = Data()
    private static let maxErrorTail = 4096
    // One serial queue owns the reader and keeps the events in order.
    private let queue = DispatchQueue(label: "fff3.now-playing")
    private var reader = NowPlayingLineReader()

    static var helperURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libfff3nowplaying.dylib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static let script = """
        use DynaLoader;
        my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $f = DynaLoader::dl_find_symbol($h, "fff3_now_playing") or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub("main::run", $f);
        run();
        """

    /// Callbacks run on a background queue, in the order the helper wrote them.
    /// `onExit` is not called after `stop()`.
    init(helper: URL, onEvent: @escaping @Sendable (NowPlayingEvent) -> Void,
         onExit: @escaping @Sendable (String) -> Void) throws {
        let output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script, helper.path]
        // A clean environment, so PERL5OPT or PERL5LIB cannot change what runs.
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At end of file the handler fires again and again until it is removed.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.queue.sync { for event in self.reader.append(data) { onEvent(event) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.keepError(data)
        }
        let queue = queue
        process.terminationHandler = { [weak self] process in
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            guard let self else { return }
            keepError(rest)
            let detail = String(decoding: lock.withLock { errorTail }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            queue.async {
                guard !self.isStopped else { return }
                onExit(detail.isEmpty ? "exit code \(process.terminationStatus)" : detail)
            }
        }
        do {
            try process.run()
        } catch {
            // Without a process the pipes never reach end of file, so drop their handlers here.
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func keepError(_ data: Data) {
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > Self.maxErrorTail { errorTail = Data(errorTail.suffix(Self.maxErrorTail)) }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        // Closing stdin makes the helper exit; terminate covers a stuck one.
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}
