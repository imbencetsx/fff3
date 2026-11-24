import XCTest
import CoreGraphics
import ImageIO
import Fff3Core
@testable import Fff3

final class SpotifyURLProtocol: URLProtocol, @unchecked Sendable {
    // Tests encode their replies in the request-specific session header, avoiding shared mutable state.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "Test-Scenario") ?? ""
        if scenario == "artwork" {
            let bytes: [UInt8] = [186, 115, 91, 255, 196, 125, 101, 255]
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data as Data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let tokenRequest = request.url!.path == "/api/token"
        let status: Int
        let body: String
        if tokenRequest {
            status = 200
            body = #"{"access_token":"renewed","expires_in":3600}"#
        } else {
            switch scenario {
            case "paused": status = 200; body = #"{"is_playing":false,"item":null}"#
            case "empty": status = 204; body = ""
            case "denied": status = 403; body = "{}"
            case "limited": status = 429; body = "{}"
            case "refresh":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed" {
                    status = 204; body = ""
                } else { status = 401; body = "{}" }
            default:
                status = 200
                body = #"{"is_playing":true,"item":{"type":"track","name":"Song","artists":[{"name":"Artist"}],"external_urls":{"spotify":"https://open.spotify.com/track/123"},"album":{"images":[{"url":"https://i.scdn.co/image/large","width":640},{"url":"https://i.scdn.co/image/medium","width":300},{"url":"https://i.scdn.co/image/small","width":64}]}}}"#
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Retry-After": "42"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SpotifyAPITests: XCTestCase {
    private func api(_ scenario: String, expired: Bool = false) -> SpotifyAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpotifyURLProtocol.self]
        config.httpAdditionalHeaders = ["Test-Scenario": scenario]
        return SpotifyAPI(credentials: SpotifyCredentials(clientID: "id", accessToken: "old", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expired ? -10 : 3600)), session: URLSession(configuration: config), persist: { _ in })
    }

    func testArtworkDecodeReturnsAnOriginalPixel() async throws {
        let selected = try await api("artwork").color(for: URL(string: "https://i.scdn.co/image/fixture")!)
        XCTAssertTrue([Rgb(0xBA735B), Rgb(0xC47D65)].contains(selected))
    }

    func testCurrentTrackUsesMediumArtwork() async throws {
        let track = try await api("playing").currentTrack()
        XCTAssertEqual(track?.title, "Song")
        XCTAssertEqual(track?.artist, "Artist")
        XCTAssertEqual(track?.artwork.absoluteString, "https://i.scdn.co/image/medium")
    }

    func testPausedAndEmptyPlaybackDoNotProduceColor() async throws {
        let paused = try await api("paused").currentTrack()
        let empty = try await api("empty").currentTrack()
        XCTAssertNil(paused)
        XCTAssertNil(empty)
    }

    func testRefreshOnExpiryAndOnceAfterUnauthorized() async throws {
        let expired = try await api("refresh", expired: true).currentTrack()
        let unauthorized = try await api("refresh").currentTrack()
        XCTAssertNil(expired)
        XCTAssertNil(unauthorized)
    }

    func testForbiddenRequiresSignIn() async {
        do {
            _ = try await api("denied").currentTrack()
            XCTFail("Expected forbidden response")
        } catch let error as SpotifyFailure {
            XCTAssertTrue(error.needsSignIn)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRateLimitPreservesRetryAfter() async {
        do {
            _ = try await api("limited").currentTrack()
            XCTFail("Expected rate limit")
        } catch let error as SpotifyFailure {
            XCTAssertEqual(error.retryAfter, 42)
            XCTAssertFalse(error.needsSignIn)
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
