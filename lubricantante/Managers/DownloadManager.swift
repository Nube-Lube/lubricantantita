import Foundation
import Combine

// MARK: - Download Status
enum DLStatus {
    case pending
    case downloading
    case done
    case error
}

// MARK: - Download Item
struct DLItem: Identifiable {
    let id = UUID()
    var title: String
    var status: DLStatus
    var message: String
}

// MARK: - YouTube Client Config
struct YTClientConfig {
    var clientName:        String = "ANDROID"
    var clientVersion:     String = "19.09.37"
    var androidSdkVersion: Int    = 30
    var userAgent:         String = "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip"
}

// MARK: - Download Manager
@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var items: [DLItem] = []
    @Published var isDownloading = false

    private let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]

    // Self-updating client config — fetched from yt-dlp source
    private var cachedConfig: YTClientConfig?
    private var configFetchedAt: Date?
    private let configTTL: TimeInterval = 86400 // 24 hours

    // yt-dlp's youtube.py always has the current working client params
    private let ytdlpSourceURL = URL(string:
        "https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/yt_dlp/extractor/youtube.py")!

    private init() {}

    // MARK: - Public API

    func start(urlString: String) {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()

        Task {
            do {
                if let listId = extractPlaylistId(from: urlString),
                   !urlString.contains("watch?v=") {
                    try await downloadPlaylist(listId: listId)
                } else if let videoId = extractVideoId(from: urlString) {
                    try await downloadVideo(videoId: videoId, album: "YouTube")
                } else {
                    addItem("Error", status: .error, message: "Could not find a video or playlist ID in that URL")
                }
            } catch {
                addItem("Error", status: .error, message: error.localizedDescription)
            }
            isDownloading = false
            LibraryManager.shared.reload()
        }
    }

    // MARK: - Self-updating client config

    private func fetchClientConfig() async -> YTClientConfig {
        // Return cached config if still fresh
        if let cfg = cachedConfig,
           let at = configFetchedAt,
           Date().timeIntervalSince(at) < configTTL {
            return cfg
        }

        // Try persisted config from UserDefaults first (works offline)
        if let saved = UserDefaults.standard.dictionary(forKey: "yt_client_config"),
           let name = saved["clientName"]    as? String,
           let ver  = saved["clientVersion"] as? String,
           let sdk  = saved["androidSdk"]   as? Int,
           let ua   = saved["userAgent"]    as? String {
            let cfg = YTClientConfig(clientName: name, clientVersion: ver,
                                     androidSdkVersion: sdk, userAgent: ua)
            cachedConfig    = cfg
            configFetchedAt = Date().addingTimeInterval(-configTTL + 3600)
        }

        // Fetch fresh config from yt-dlp source
        do {
            let (data, _) = try await URLSession.shared.data(from: ytdlpSourceURL)
            if let source = String(data: data, encoding: .utf8) {
                let config = parseYTDLPSource(source)
                cachedConfig    = config
                configFetchedAt = Date()
                UserDefaults.standard.set([
                    "clientName":    config.clientName,
                    "clientVersion": config.clientVersion,
                    "androidSdk":    config.androidSdkVersion,
                    "userAgent":     config.userAgent,
                ], forKey: "yt_client_config")
                return config
            }
        } catch {
            // Network failed — use cached or hardcoded fallback
        }

        return cachedConfig ?? YTClientConfig()
    }

    private func parseYTDLPSource(_ source: String) -> YTClientConfig {
        var config = YTClientConfig()
        let lines = source.components(separatedBy: "\n")
        var inAndroidBlock = false
        var braceDepth = 0

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)

            if !inAndroidBlock && t.contains("'ANDROID'") && t.contains("{") {
                inAndroidBlock = true; braceDepth = 1; continue
            }

            if inAndroidBlock {
                braceDepth += t.filter { $0 == "{" }.count
                braceDepth -= t.filter { $0 == "}" }.count
                if braceDepth <= 0 { inAndroidBlock = false; continue }

                if t.contains("'clientVersion'"),
                   let v = extractStringValue(from: t) {
                    config.clientVersion = v
                    config.userAgent = "com.google.android.youtube/\(v) (Linux; U; Android 11) gzip"
                }
                if t.contains("androidSdkVersion"),
                   let sdk = extractIntValue(from: t) {
                    config.androidSdkVersion = sdk
                }
            }
        }
        return config
    }

    private func extractStringValue(from line: String) -> String? {
        guard let r = line.range(of: "'([0-9]+\\.[0-9]+\\.[0-9]+)'",
                                  options: .regularExpression),
              let vr = line[r].range(of: "[0-9]+\\.[0-9]+\\.[0-9]+",
                                     options: .regularExpression)
        else { return nil }
        return String(line[r][vr])
    }

    private func extractIntValue(from line: String) -> Int? {
        guard let r = line.range(of: ":\\s*(\\d+)", options: .regularExpression),
              let nr = line[r].range(of: "\\d+", options: .regularExpression)
        else { return nil }
        return Int(line[r][nr])
    }

    // MARK: - Playlist (InnerTube browse API)

    private func downloadPlaylist(listId: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist…")

        let browseURL = URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var req = URLRequest(url: browseURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": [
                "client": ["clientName": "WEB", "clientVersion": "2.20231121.08.00"]
            ]
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ytErr("Could not parse playlist response")
        }

        // Extract playlist name
        var playlistName = "YouTube Playlist"
        if let h = json["header"] as? [String: Any],
           let r = h["playlistHeaderRenderer"] as? [String: Any],
           let t = r["title"] as? [String: Any],
           let runs = t["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String {
            playlistName = text
        } else if let m = json["metadata"] as? [String: Any],
                  let r = m["playlistMetadataRenderer"] as? [String: Any],
                  let t = r["title"] as? String {
            playlistName = t
        }

        // Extract video IDs
        var videoIds: [String] = []
        extractVideoIds(from: json, into: &videoIds)

        guard !videoIds.isEmpty else {
            throw ytErr("No videos found in playlist — it may be private or empty")
        }

        updateItem("Playlist", status: .pending,
                   message: "\(playlistName) — \(videoIds.count) tracks")

        for videoId in videoIds {
            try await downloadVideo(videoId: videoId, album: playlistName)
        }
    }

    private func extractVideoIds(from obj: Any, into ids: inout [String]) {
        if let dict = obj as? [String: Any] {
            if let r = dict["playlistVideoRenderer"] as? [String: Any],
               let vid = r["videoId"] as? String,
               !ids.contains(vid) {
                ids.append(vid)
            }
            dict.values.forEach { extractVideoIds(from: $0, into: &ids) }
        } else if let arr = obj as? [Any] {
            arr.forEach { extractVideoIds(from: $0, into: &ids) }
        }
    }

    // MARK: - Single video (InnerTube player API)

    private func downloadVideo(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        addItem(key, status: .downloading, message: "Fetching stream…")

        // Get auth headers and PO token
        let authHeaders = await AuthManager.shared.authHeaders()
        let poToken = (try? await POTokenManager.shared.getToken(
            for: videoId, visitorData: "")) ?? ""

        let playerURL = URL(string:
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var req = URLRequest(url: playerURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 30
        for (k, v) in authHeaders { req.setValue(v, forHTTPHeaderField: k) }

        var clientContext: [String: Any] = [
            "clientName":    "WEB",
            "clientVersion": "2.20231121.08.00",
            "hl":            "en",
            "gl":            "US",
        ]
        if !poToken.isEmpty {
            clientContext["poToken"] = poToken
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": videoId,
            "context": ["client": clientContext]
        ])

        var data: Data
        var resp: URLResponse
        (data, resp) = try await URLSession.shared.data(for: req)

        // Fallback to WEB client if embedded player gets 400
        if (resp as? HTTPURLResponse)?.statusCode == 400 {
            var req2 = URLRequest(url: playerURL)
            req2.httpMethod = "POST"
            req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req2.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            req2.timeoutInterval = 30
            for (k, v) in authHeaders { req2.setValue(v, forHTTPHeaderField: k) }
            req2.httpBody = try JSONSerialization.data(withJSONObject: [
                "videoId": videoId,
                "context": [
                    "client": [
                        "clientName":    "WEB",
                        "clientVersion": "2.20231121.08.00",
                        "hl": "en", "gl": "US",
                    ]
                ]
            ])
            (data, resp) = try await URLSession.shared.data(for: req2)
        }

        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            if !AuthManager.shared.isSignedIn {
                throw ytErr("Sign in to your Google account in Settings to download")
            }
            throw ytErr("Server returned \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ytErr("Bad JSON response")
        }

        if let ps = json["playabilityStatus"] as? [String: Any] {
            let status = ps["status"] as? String ?? "OK"
            // Only hard-fail on login required or content error
            // UNPLAYABLE and AGE_CHECK_REQUIRED may still have streams
            if status == "ERROR" || status == "LOGIN_REQUIRED" {
                throw ytErr(ps["reason"] as? String ?? "Video unavailable")
            }
        }

        let title = (json["videoDetails"] as? [String: Any])?["title"]
                    as? String ?? "YouTube Track"

        let formats = ((json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]) ?? []

        // Debug: log what format types are available
        let allMimeTypes = formats.compactMap { $0["mimeType"] as? String }
        let hasUrls = formats.filter { $0["url"] is String }.count
        let hasCiphers = formats.filter { $0["signatureCipher"] is String || $0["cipher"] is String }.count

        let audioOnly = formats
            .filter { f in
                guard let mime = f["mimeType"] as? String else { return false }
                return mime.hasPrefix("audio") && (f["url"] is String ||
                       f["signatureCipher"] is String || f["cipher"] is String)
            }
            .sorted { a, b in
                (a["bitrate"] as? Int ?? 0) > (b["bitrate"] as? Int ?? 0)
            }

        guard let best = audioOnly.first else {
            let debugMsg = "No audio stream. Formats: \(allMimeTypes.prefix(5).joined(separator: ", ")). URLs: \(hasUrls), Ciphers: \(hasCiphers)"
            throw ytErr(debugMsg)
        }

        // Handle both direct URL and signatureCipher formats
        let rawUrl: String?
        if let direct = best["url"] as? String {
            rawUrl = direct
        } else if let cipher = best["signatureCipher"] as? String ?? best["cipher"] as? String {
            let parts = cipher.components(separatedBy: "&")
            rawUrl = parts
                .first(where: { $0.hasPrefix("url=") })?
                .dropFirst(4)
                .removingPercentEncoding
        } else {
            rawUrl = nil
        }

        guard let urlStr = rawUrl, let audioURL = URL(string: urlStr) else {
            throw ytErr("Could not extract audio URL from stream data")
        }

        let mime = (best["mimeType"] as? String)?
            .components(separatedBy: ";").first ?? "audio/mp4"
        let ext  = mime.contains("webm") || mime.contains("opus") ? "webm" : "m4a"

        updateItem(key, newTitle: title, status: .downloading,
                   message: "Downloading…")

        // Download to temp then move to Documents
        let (tmpURL, _) = try await URLSession.shared.download(from: audioURL)
        let safe     = sanitize(title)
        let albumDir = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(
            at: albumDir, withIntermediateDirectories: true)
        let dest = albumDir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try  FileManager.default.moveItem(at: tmpURL, to: dest)

        let track = Track(
            id:       UUID(),
            name:     title,
            album:    album,
            filename: "\(sanitize(album))/\(safe).\(ext)",
            addedAt:  Date()
        )
        LibraryManager.shared.add(track)
        updateItem(title, status: .done, message: "Saved ✓")
    }

    // MARK: - Utilities

    private func ytErr(_ msg: String) -> NSError {
        NSError(domain: "YouTube", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "[/\\\\:*?\"<>|]",
                               with: "_", options: .regularExpression)
         .trimmingCharacters(in: .whitespaces)
    }

    private func extractVideoId(from url: String) -> String? {
        guard let r  = url.range(of: "(?:v=|youtu\\.be/|/embed/)([A-Za-z0-9_-]{11})",
                                  options: .regularExpression),
              let vr = url[r].range(of: "[A-Za-z0-9_-]{11}",
                                    options: .regularExpression)
        else { return nil }
        return String(url[r][vr])
    }

    private func extractPlaylistId(from url: String) -> String? {
        guard let r = url.range(of: "[?&]list=([A-Za-z0-9_-]+)",
                                 options: .regularExpression)
        else { return nil }
        return String(url[r])
            .components(separatedBy: "list=").last?
            .components(separatedBy: "&").first
    }

    // MARK: - UI helpers

    private func addItem(_ title: String, status: DLStatus, message: String) {
        items.append(DLItem(title: title, status: status, message: message))
    }

    private func updateItem(_ title: String,
                            newTitle: String? = nil,
                            status: DLStatus,
                            message: String) {
        guard let i = items.firstIndex(where: { $0.title == title })
        else { return }
        items[i].status  = status
        items[i].message = message
        if let t = newTitle { items[i].title = t }
    }
}