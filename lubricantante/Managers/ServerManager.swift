import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ServerManager
// Stores the local WiFi address of server.py and pings it to confirm
// it's reachable with yt-dlp available.
//
// Uses a custom URLSession delegate so self-signed HTTPS certs on the local
// network are accepted (server.py generates one via openssl on first run).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class ServerManager: ObservableObject {
    static let shared = ServerManager()

    /// Raw URL the user typed, e.g. "http://192.168.1.42:5000"
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "srv_url_v1") }
    }

    @Published var isConnected  = false
    @Published var isPinging    = false
    @Published var trackCount   = 0
    @Published var hasYtdlp     = false
    @Published var errorMessage = ""

    /// URLSession that accepts self-signed certs — only used for local IPs.
    let localSession: URLSession = {
        let delegate = LocalCertDelegate()
        return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }()

    private struct PingResponse: Decodable {
        let name:   String
        let tracks: Int
        let ytdlp:  Bool
        let version: Int?
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "srv_url_v1") ?? ""
        if !serverURL.isEmpty {
            Task { await ping() }
        }
    }

    /// Normalized base URL — no trailing slash.
    var base: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                 .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // ── Ping ─────────────────────────────────────────────────────────────
    func ping() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/ping") else {
            isConnected  = false
            errorMessage = "Enter a valid server URL (e.g. http://192.168.1.x:5000)"
            return
        }
        isPinging    = true
        errorMessage = ""
        defer { isPinging = false }

        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let session = base.hasPrefix("https") ? localSession : URLSession.shared
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let p       = try JSONDecoder().decode(PingResponse.self, from: data)
            trackCount  = p.tracks
            hasYtdlp    = p.ytdlp
            isConnected = true
        } catch {
            isConnected  = false
            let msg = error.localizedDescription
            if msg.contains("timed out") || msg.contains("timed out") {
                errorMessage = "Timed out — make sure your phone and Mac are on the same WiFi and the URL is correct"
            } else if msg.contains("certificate") || msg.contains("SSL") {
                errorMessage = "HTTPS cert error — try http:// instead of https://"
            } else {
                errorMessage = "Could not reach server: \(msg)"
            }
        }
    }

    func disconnect() {
        isConnected  = false
        trackCount   = 0
        hasYtdlp     = false
        errorMessage = ""
    }
}

// ── Accepts self-signed certs for local network IPs only ─────────────────────
class LocalCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if isLocalAddress(host) &&
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func isLocalAddress(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("10.")      { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let n = Int(parts[1]), (16...31).contains(n) { return true }
        }
        return false
    }
}