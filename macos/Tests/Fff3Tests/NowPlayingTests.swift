import XCTest
import ImageIO
@testable import Fff3
import Fff3Core

final class NowPlayingTests: XCTestCase {
    func testReaderJoinsSplitLinesAndSkipsBadOnes() {
        var reader = NowPlayingLineReader()
        let first = #"{"players":[{"id":"a","title":"Body","artist":"Don Toliver","album":"OCTANE","app":"Spotify","active":true,"playing":true,"hasArtwork":true,"artwork":"AQID"}]}"#
        let second = #"{"players":[{"id":"a","title":"Body","artist":"Don Toliver","album":"OCTANE","app":"Spotify","active":false,"playing":false,"hasArtwork":true}]}"#
        let text = first + "\nnot json\n" + second + "\n"
        let bytes = Data(text.utf8)
        let cut = 40
        XCTAssertEqual(reader.append(bytes[..<cut]), [])
        let events = reader.append(bytes[cut...])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].players[0].title, "Body")
        XCTAssertEqual(events[0].players[0].artwork, Data([1, 2, 3]))
        XCTAssertTrue(events[0].players[0].active)
        XCTAssertNil(events[1].players[0].artwork)
        XCTAssertFalse(events[1].players[0].playing)
        XCTAssertFalse(events[1].players[0].active)
    }

    func testCoverBytesGiveTheirMainColour() throws {
        // A plain blue JPEG, like the covers players hand to Now Playing.
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cover = jpeg as Data
        let color = try XCTUnwrap(ArtworkImage.color(cover))
        XCTAssertGreaterThan(color.blue, 200)
        XCTAssertLessThan(color.red, 60)
        XCTAssertNil(ArtworkImage.color(Data([1, 2, 3])))
    }
}

final class NowPlayingFilterTests: XCTestCase {
    private func event(bundle: String, parent: String = "", mediaType: String = "kMRMediaRemoteNowPlayingInfoTypeAudio",
                       strict: String = "audio", active: Bool = false, playing: Bool = true) -> NowPlayingPlayer {
        NowPlayingPlayer(id: bundle, title: "Song", artist: "Artist", album: "", app: "", bundle: bundle, parent: parent,
                         mediaType: mediaType, strictMediaType: strict, active: active, playing: playing, hasArtwork: true)
    }

    func testMusicKeepsTheLightsWhenABrowserVideoTakesOver() {
        let video = event(bundle: "com.google.Chrome", mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo", strict: "video", active: true)
        let music = event(bundle: "com.spotify.client")
        let pick = NowPlayingFilter.pick([video, music], browsers: [])
        XCTAssertEqual(pick.player?.id, "com.spotify.client")
        XCTAssertEqual(pick.ignored, "Browsers don't change the lights")
    }

    func testPlayingMusicBeatsPausedMusicAndPausedMusicBeatsVideo() {
        let paused = event(bundle: "com.apple.Music", active: true, playing: false)
        let playing = event(bundle: "str-now-playing")
        XCTAssertEqual(NowPlayingFilter.pick([paused, playing], browsers: []).player?.id, "str-now-playing")
        let video = event(bundle: "com.colliderli.iina", strict: "video", active: true)
        let pick = NowPlayingFilter.pick([video, paused], browsers: [])
        XCTAssertEqual(pick.player?.id, "com.apple.Music")
        XCTAssertEqual(pick.ignored, "Videos don't change the lights")
        // With two playing music players, the one Control Centre shows wins.
        let shown = event(bundle: "com.apple.Music", active: true)
        XCTAssertEqual(NowPlayingFilter.pick([playing, shown], browsers: []).player?.id, "com.apple.Music")
    }

    func testOnlyAVideoMeansNoPlayerAndAReason() {
        let pick = NowPlayingFilter.pick([event(bundle: "org.mozilla.firefox", active: true)], browsers: [])
        XCTAssertNil(pick.player)
        XCTAssertEqual(pick.ignored, "Browsers don't change the lights")
        XCTAssertNil(NowPlayingFilter.pick([], browsers: []).ignored)
    }

    func testMusicPlayersAndTerminalPlayersPass() {
        for id in ["com.spotify.client", "com.apple.Music", "com.mitchellh.ghostty", "str-now-playing", ""] {
            XCTAssertNil(NowPlayingFilter.skipReason(event(bundle: id), browsers: []), id)
        }
    }

    func testBrowsersAreSkippedEvenFromHelpersOrUnlisted() {
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.google.Chrome.helper"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.apple.WebKit.GPU", parent: "com.apple.Safari"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "org.mozilla.firefox"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.oasis.browser"), browsers: ["com.oasis.browser"]))
        // A prefix only counts at a dot: "com.vivaldiX" is not Vivaldi.
        XCTAssertNil(NowPlayingFilter.skipReason(event(bundle: "com.vivaldiX"), browsers: []))
    }

    func testVideoAndPodcastsAreSkipped() {
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.colliderli.iina", mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo", strict: "video"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "org.videolan.vlc", mediaType: "", strict: "video"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.apple.TV"), browsers: []))
        XCTAssertNotNil(NowPlayingFilter.skipReason(event(bundle: "com.apple.podcasts"), browsers: []))
    }
}
