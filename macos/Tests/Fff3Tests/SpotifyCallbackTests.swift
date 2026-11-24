import XCTest
@testable import Fff3

final class SpotifyCallbackTests: XCTestCase {
    @MainActor
    func testLoopbackCallbackReceivesURLWithoutExposingCode() async throws {
        let ready = expectation(description: "Loopback listener ready")
        let received = expectation(description: "Callback received")
        let server = try SpotifyCallbackServer(onReady: { ready.fulfill() }, onURL: { url in
            XCTAssertEqual(url.path, "/spotify/callback")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "test-code")
            received.fulfill()
        }, onError: { XCTFail("Loopback listener failed") })
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let url = URL(string: "http://127.0.0.1:43821/spotify/callback?code=test-code&state=test-state")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Return to [rgb]"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-code"))
        await fulfillment(of: [received], timeout: 3)
    }
}
