import XCTest
@testable import Fff3Core

final class SpotifyTests: XCTestCase {
    func testPKCEStandardVector() {
        // RFC 7636, Appendix B: verifies SHA-256 and base64url encoding together.
        XCTAssertEqual(SpotifyOAuth.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationRequestsOnlyCurrentTrack() throws {
        let url = SpotifyOAuth.authorizationURL(clientID: "client", verifier: "verifier", state: "random-state")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parts.host, "accounts.spotify.com")
        XCTAssertEqual(query["scope"], "user-read-currently-playing")
        XCTAssertEqual(query["redirect_uri"], SpotifyOAuth.redirectURI)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "random-state")
        XCTAssertNil(query["client_secret"])
    }

    func testCallbackRejectsWrongOriginStateAndDenial() {
        let good = "http://127.0.0.1:43821/spotify/callback?code=valid&state=expected"
        XCTAssertEqual(SpotifyOAuth.callbackCode(URL(string: good)!, state: "expected"), "valid")
        for invalid in [
            good.replacingOccurrences(of: "expected", with: "other"),
            good.replacingOccurrences(of: "127.0.0.1", with: "example.com"),
            good.replacingOccurrences(of: "43821", with: "1234"),
            good.replacingOccurrences(of: "/spotify/callback", with: "/other"),
            good + "&error=access_denied", good + "&state=expected", good + "&code=second",
            "http://127.0.0.1:43821/spotify/callback?code=&state=expected",
        ] {
            XCTAssertNil(SpotifyOAuth.callbackCode(URL(string: invalid)!, state: "expected"), invalid)
        }
    }

    func testFormEscapesReservedCharacters() {
        XCTAssertEqual(String(data: SpotifyOAuth.form(["code": "a+b&c=d /", "client_id": "id"]), encoding: .utf8),
                       "client_id=id&code=a%2Bb%26c%3Dd%20%2F")
    }

    func testAlbumColorIgnoresBlackAndWhiteBorders() {
        let red: [UInt8] = [224, 32, 48, 255]
        let black: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [255, 255, 255, 255]
        let pixels = Array(repeating: black, count: 50).flatMap { $0 }
            + Array(repeating: white, count: 40).flatMap { $0 }
            + Array(repeating: red, count: 10).flatMap { $0 }
        XCTAssertEqual(ArtworkColor.dominant(rgba: pixels), Rgb(0xE02030))
    }

    func testAlbumColorKeepsGrayscaleAndRejectsEmptyOrTransparent() {
        XCTAssertEqual(ArtworkColor.dominant(rgba: [120, 120, 120, 255]), Rgb(0x787878))
        XCTAssertEqual(ArtworkColor.dominant(rgba: [0, 0, 0, 255]), .black)
        XCTAssertEqual(ArtworkColor.dominant(rgba: [255, 255, 255, 255]), .white)
        XCTAssertNil(ArtworkColor.dominant(rgba: []))
        XCTAssertNil(ArtworkColor.dominant(rgba: [255, 0, 0]))
        XCTAssertNil(ArtworkColor.dominant(rgba: [255, 0, 0, 0]))
    }
}
