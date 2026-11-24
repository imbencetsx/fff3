import Foundation
import Network

/// Spotify allows HTTP redirects only on loopback. Bind only to this Mac.
@MainActor
final class SpotifyCallbackServer {
    private let listener: NWListener

    init(onReady: @escaping @Sendable () -> Void, onURL: @escaping @Sendable (URL) -> Void,
         onError: @escaping @Sendable () -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady()
            case .failed: onError()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            Self.receive(connection, data: Data(), onURL: onURL)
            // A browser connection that never completes its headers must not stay open.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { connection.cancel() }
        }
        listener.start(queue: DispatchQueue(label: "fff3.spotify.callback"))
    }

    func stop() { listener.cancel() }

    nonisolated private static func receive(_ connection: NWConnection, data: Data,
                                            onURL: @escaping @Sendable (URL) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, done, error in
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 8192, error == nil else { connection.cancel(); return }
            guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                if done { connection.cancel() } else { receive(connection, data: data, onURL: onURL) }
                return
            }
            let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/spotify/callback?"),
                  let url = URL(string: "http://127.0.0.1:43821\(parts[1])") else {
                connection.cancel(); return
            }
            let body = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>[rgb] Spotify</title><p>Return to [rgb] to finish connecting Spotify. You can close this tab.</p></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            onURL(url)
        }
    }
}
