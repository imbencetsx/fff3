import Foundation
import Security
import Fff3Core

struct SpotifyFailure: LocalizedError {
    let message: String
    var retryAfter: Double? = nil
    var needsSignIn = false
    var errorDescription: String? { message }
}

struct SpotifyCredentials: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum SpotifyKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.kernoeb.fff3.mac.spotify",
         kSecAttrAccount as String: "spotify"]
    }

    static func load() -> SpotifyCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyCredentials.self, from: data)
    }

    static func save(_ credentials: SpotifyCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SpotifyFailure(message: "Could not save Spotify sign-in in Keychain. Unlock Keychain and try again.")
            }
        } else if status != errSecSuccess {
            throw SpotifyFailure(message: "Could not update Spotify sign-in in Keychain. Unlock Keychain and try again.")
        }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpotifyFailure(message: "Could not remove Spotify sign-in from Keychain. Unlock Keychain and try again.")
        }
    }
}

struct SpotifyTrack: Sendable {
    let title: String
    let artist: String
    let url: URL
    let artwork: URL
}

private struct SpotifyPlayback: Decodable {
    let is_playing: Bool
    let item: Item?
    struct Item: Decodable {
        let type: String
        let name: String
        let artists: [Artist]?
        let album: Album?
        let external_urls: [String: String]?
    }
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let images: [Image] }
    struct Image: Decodable { let url: URL; let width: Int? }

    var track: SpotifyTrack? {
        guard is_playing, let item, item.type == "track",
              let url = item.external_urls?["spotify"].flatMap(URL.init(string:)),
              let artwork = item.album?.images.min(by: { abs(($0.width ?? 300) - 300) < abs(($1.width ?? 300) - 300) })?.url,
              artwork.scheme == "https" else { return nil }
        return SpotifyTrack(title: item.name, artist: item.artists?.map(\.name).joined(separator: ", ") ?? "", url: url, artwork: artwork)
    }
}

actor SpotifyAPI {
    private var credentials: SpotifyCredentials?
    private let session: URLSession
    private let persist: @Sendable (SpotifyCredentials) throws -> Void
    private var cachedArtwork: (URL, Rgb)?

    init(credentials: SpotifyCredentials?, session: URLSession? = nil,
         persist: @escaping @Sendable (SpotifyCredentials) throws -> Void = SpotifyKeychain.save) {
        self.credentials = credentials
        self.persist = persist
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    func signIn(clientID: String, code: String, verifier: String) async throws {
        try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": SpotifyOAuth.redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ], clientID: clientID)
    }

    func use(_ credentials: SpotifyCredentials) {
        self.credentials = credentials
    }

    func disconnect() throws {
        try SpotifyKeychain.delete()
        credentials = nil
        cachedArtwork = nil
    }

    private func token(_ values: [String: String], clientID: String) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyOAuth.form(values)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SpotifyFailure(message: "Spotify returned an invalid response.") }
        if http.statusCode == 429 { throw rateLimit(http) }
        guard http.statusCode == 200 else {
            // Only a rejected grant needs a new sign-in; a server error is retried.
            guard (400..<500).contains(http.statusCode) else {
                throw SpotifyFailure(message: "Spotify is unavailable (HTTP \(http.statusCode)). Retrying shortly.")
            }
            throw SpotifyFailure(message: "Spotify sign-in expired or was rejected. Check your Client ID and redirect URI, then connect again.", needsSignIn: true)
        }
        struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double }
        let value = try JSONDecoder().decode(Token.self, from: data)
        let previousRefresh = values["grant_type"] == "refresh_token" ? credentials?.refreshToken : nil
        guard let refresh = value.refresh_token ?? previousRefresh else {
            throw SpotifyFailure(message: "Spotify did not return a refresh token. Connect again.", needsSignIn: true)
        }
        let next = SpotifyCredentials(clientID: clientID, accessToken: value.access_token, refreshToken: refresh,
                                      expiresAt: Date().addingTimeInterval(value.expires_in))
        // Keep the new tokens even if Keychain fails: Spotify may have replaced the old refresh token.
        credentials = next
        try persist(next)
    }

    func currentTrack() async throws -> SpotifyTrack? {
        guard let saved = credentials else { throw SpotifyFailure(message: "Connect Spotify first.", needsSignIn: true) }
        if saved.expiresAt.timeIntervalSinceNow < 60 { try await refresh() }
        for attempt in 0..<2 {
            guard let credentials else { throw SpotifyFailure(message: "Connect Spotify again.", needsSignIn: true) }
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SpotifyFailure(message: "Spotify returned an invalid response.") }
            switch http.statusCode {
            case 200: return try JSONDecoder().decode(SpotifyPlayback.self, from: data).track
            case 204: return nil
            case 401 where attempt == 0: try await refresh()
            case 401: throw SpotifyFailure(message: "Spotify sign-in expired. Connect again.", needsSignIn: true)
            case 403: throw SpotifyFailure(message: "Spotify denied access. Check your app's allowed users and Premium requirements in the Spotify developer dashboard.", needsSignIn: true)
            case 429: throw rateLimit(http)
            default: throw SpotifyFailure(message: "Spotify is unavailable (HTTP \(http.statusCode)). Retrying shortly.")
            }
        }
        return nil
    }

    private func refresh() async throws {
        guard let credentials else { throw SpotifyFailure(message: "Connect Spotify again.", needsSignIn: true) }
        try await token(["grant_type": "refresh_token", "refresh_token": credentials.refreshToken,
                         "client_id": credentials.clientID], clientID: credentials.clientID)
    }

    private func rateLimit(_ response: HTTPURLResponse) -> SpotifyFailure {
        SpotifyFailure(message: "Spotify asked [rgb] to slow down. Waiting before retrying.",
                       retryAfter: max(5, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30))
    }

    func color(for artwork: URL) async throws -> Rgb {
        if let cachedArtwork, cachedArtwork.0 == artwork { return cachedArtwork.1 }
        let (data, response) = try await session.data(from: artwork)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, let color = ArtworkImage.color(data) else {
            throw SpotifyFailure(message: "Could not read this album's artwork. Retrying shortly.")
        }
        cachedArtwork = (artwork, color)
        return color
    }
}
