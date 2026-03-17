import Foundation
import AVFoundation

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

// MARK: - Download Manager
@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    
    @Published var items: [DLItem] = []
    @Published var isDownloading = false
    
    private var activeDownloads = 0
    private let maxConcurrent = 3
    
    // YouTube config cache
    private var cachedConfig: [String: Any]?
    private var configLastFetched: Date?
    private let configCacheLifetime: TimeInterval = 3600 // 1 hour
    
    private init() {}
    
    // MARK: - Public API
    
    func start(urlString: String) {
        Task {
            if urlString.contains("list=") {
                await downloadPlaylist(url: urlString)
            } else {
                await downloadSingleVideo(url: urlString)
            }
        }
    }
    
    private func downloadPlaylist(url: String) async {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()
        
        do {
            let videoIDs = try await extractVideoIDs(from: url)
            
            for id in videoIDs {
                items.append(DLItem(
                    title: id,
                    status: .pending,
                    message: "Queued"
                ))
            }
            
            // Download with concurrency limit
            await withTaskGroup(of: Void.self) { group in
                for id in videoIDs {
                    // Wait if we're at max concurrent downloads
                    while activeDownloads >= maxConcurrent {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    }
                    
                    group.addTask {
                        await self.downloadVideo(id: id)
                    }
                }
            }
            
        } catch {
            print("Playlist extraction failed: \(error)")
        }
        
        isDownloading = false
    }
    
    private func downloadSingleVideo(url: String) async {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()
        
        if let id = extractVideoID(from: url) {
            items.append(DLItem(
                title: id,
                status: .pending,
                message: "Queued"
            ))
            await downloadVideo(id: id)
        }
        
        isDownloading = false
    }
    
    // MARK: - Video ID Extraction
    
    private func extractVideoIDs(from url: String) async throws -> [String] {
        // Try playlist first
        if let playlistID = url.range(of: "list=")?.upperBound {
            let idEnd = url[playlistID...].firstIndex(of: "&") ?? url.endIndex
            let listID = String(url[playlistID..<idEnd])
            
            let playlistURL = "https://www.youtube.com/playlist?list=\(listID)"
            let (data, _) = try await URLSession.shared.data(from: URL(string: playlistURL)!)
            
            guard let html = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "YouTube", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            
            var videoIDs: [String] = []
            let pattern = #"\"videoId\":\"([a-zA-Z0-9_-]{11})\""#
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            
            for match in matches {
                if let range = Range(match.range(at: 1), in: html) {
                    let id = String(html[range])
                    if !videoIDs.contains(id) {
                        videoIDs.append(id)
                    }
                }
            }
            
            return videoIDs
        }
        
        // Single video
        if let id = extractVideoID(from: url) {
            return [id]
        }
        
        throw NSError(domain: "YouTube", code: 2, userInfo: [NSLocalizedDescriptionKey: "No videos found"])
    }
    
    private func extractVideoID(from url: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})"#,
            #"^([a-zA-Z0-9_-]{11})$"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
    
    // MARK: - Download Logic
    
    private func downloadVideo(id: String) async {
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        
        do {
            // Get video info
            updateItem(id, status: .downloading, message: "Fetching info…")
            
            let info = try await fetchVideoInfo(id: id)
            guard let title = info["title"] as? String,
                  let streamURL = info["url"] as? String else {
                updateItem(id, status: .error, message: "Missing data")
                return
            }
            
            // Sanitize filename
            let safeTitle = title.replacingOccurrences(of: "[^a-zA-Z0-9 .-]", with: "", options: .regularExpression)
            
            // Download audio
            let key = id
            updateItem(key, newTitle: title, status: .downloading, message: "Downloading…")
            
            try await downloadAudio(from: streamURL, title: safeTitle)
            updateItem(title, status: .done, message: "Saved ✓")
            
        } catch {
            updateItem(id, status: .error, message: error.localizedDescription)
        }
    }
    
    private func fetchVideoInfo(id: String) async throws -> [String: Any] {
        // Get config
        let config = try await getYouTubeConfig()
        
        guard let key = config["INNERTUBE_API_KEY"] as? String,
              let context = config["INNERTUBE_CONTEXT"] as? [String: Any] else {
            throw NSError(domain: "YouTube", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid config"])
        }
        
        // Build request
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(key)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "videoId": id,
            "context": context
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "YouTube", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }
        
        // Extract title
        let details = (json["videoDetails"] as? [String: Any]) ?? [:]
        let title = details["title"] as? String ?? "Unknown"
        
        // Extract stream URL
        guard let streamingData = json["streamingData"] as? [String: Any],
              let formats = streamingData["adaptiveFormats"] as? [[String: Any]] else {
            throw NSError(domain: "YouTube", code: 5, userInfo: [NSLocalizedDescriptionKey: "No streams found"])
        }
        
        let audioOnly = formats
            .filter { ($0["mimeType"] as? String)?.hasPrefix("audio") == true
                      && $0["url"] is String }
            .sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }
        
        guard let best = audioOnly.first,
              let url = best["url"] as? String else {
            throw NSError(domain: "YouTube", code: 6, userInfo: [NSLocalizedDescriptionKey: "No audio stream"])
        }
        
        return ["title": title, "url": url]
    }
    
    private func getYouTubeConfig() async throws -> [String: Any] {
        // Return cached if still valid
        if let cached = cachedConfig,
           let lastFetch = configLastFetched,
           Date().timeIntervalSince(lastFetch) < configCacheLifetime {
            return cached
        }
        
        // Fetch fresh config
        let url = URL(string: "https://www.youtube.com/")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "YouTube", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid HTML"])
        }
        
        // Extract INNERTUBE_API_KEY
        guard let keyRange = html.range(of: #"\"INNERTUBE_API_KEY\":\"([^\"]+)\""#, options: .regularExpression),
              let keyMatch = try? NSRegularExpression(pattern: #"\"INNERTUBE_API_KEY\":\"([^\"]+)\""#)
                .firstMatch(in: html, range: NSRange(keyRange, in: html)),
              let keyValueRange = Range(keyMatch.range(at: 1), in: html) else {
            throw NSError(domain: "YouTube", code: 8, userInfo: [NSLocalizedDescriptionKey: "API key not found"])
        }
        let apiKey = String(html[keyValueRange])
        
        // Extract INNERTUBE_CONTEXT
        guard let _ = html.range(of: #"\"INNERTUBE_CONTEXT\":(\{[^}]+\})"#, options: .regularExpression),
              let contextMatch = try? NSRegularExpression(pattern: #"\"INNERTUBE_CONTEXT\":(\{.+?\})\s*,\s*\"INNERTUBE"#)
                .firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let contextValueRange = Range(contextMatch.range(at: 1), in: html) else {
            throw NSError(domain: "YouTube", code: 9, userInfo: [NSLocalizedDescriptionKey: "Context not found"])
        }
        
        let contextJSON = String(html[contextValueRange])
        guard let contextData = contextJSON.data(using: .utf8),
              let context = try? JSONSerialization.jsonObject(with: contextData) as? [String: Any] else {
            throw NSError(domain: "YouTube", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid context"])
        }
        
        let config = [
            "INNERTUBE_API_KEY": apiKey,
            "INNERTUBE_CONTEXT": context
        ] as [String: Any]
        
        // Cache it
        cachedConfig = config
        configLastFetched = Date()
        
        return config
    }
    
    private func downloadAudio(from urlString: String, title: String) async throws {
        let url = URL(string: urlString)!
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        
        // Determine format
        let ext: String
        if urlString.contains("mime=audio%2Fwebm") || urlString.contains("mime=audio/webm") {
            ext = "webm"
        } else if urlString.contains("mime=audio%2Fmp4") || urlString.contains("mime=audio/mp4") {
            ext = "m4a"
        } else {
            ext = "m4a" // default
        }
        
        // Get documents directory and create Songs folder
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let songsDir = docs.appendingPathComponent("Songs")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        
        // Save to library
        let destURL = songsDir.appendingPathComponent("\(title).\(ext)")
        
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        
        // Trigger library reload
        await LibraryManager.shared.reload()
    }
    
    // MARK: - UI Updates
    
    private func updateItem(_ title: String,
                          newTitle: String? = nil,
                          status: DLStatus? = nil,
                          message: String) {
        if let idx = items.firstIndex(where: { $0.title == title }) {
            if let newTitle = newTitle {
                items[idx].title = newTitle
            }
            if let status = status {
                items[idx].status = status
            }
            items[idx].message = message
        }
    }
}
