import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ServerManager
// Stores the local WiFi address of server.py and pings it to confirm
// it's reachable with yt-dlp available.
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

    private struct PingResponse: Decodable {
        let name:    String
        let tracks:  Int
        let ytdlp:   Bool
        let version: Int?
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "srv_url_v1") ?? ""
        // Auto-connect on launch if we have a saved URL
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
            isConnected = false
            errorMessage = "Enter a valid server URL (e.g. http://192.168.1.x:5000)"
            return
        }
        isPinging    = true
        errorMessage = ""
        defer { isPinging = false }

        do {
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let p       = try JSONDecoder().decode(PingResponse.self, from: data)
            trackCount  = p.tracks
            hasYtdlp    = p.ytdlp
            isConnected = true
        } catch {
            isConnected  = false
            errorMessage = "Could not reach server: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        isConnected  = false
        trackCount   = 0
        hasYtdlp     = false
        errorMessage = ""
    }
}