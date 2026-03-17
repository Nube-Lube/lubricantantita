import Foundation
import WebKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// DownloadManager
//
// Uses WKWebView to load YouTube and intercept its own player API responses.
// This is the only reliable approach on iOS — we let YouTube's own JavaScript
// run BotGuard/PO token generation, then intercept the stream URLs it fetches.
// ─────────────────────────────────────────────────────────────────────────────

enum DLStatus { case pending, downloading, done, error }

struct DLItem: Identifiable {
    let id      = UUID()
    var title:   String
    var status:  DLStatus
    var message: String
}

@MainActor
class DownloadManager: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = DownloadManager()

    @Published var items: [DLItem] = []
    @Published var isDownloading   = false

    private var webView:   WKWebView?
    private var pendingVideoIds: [String] = []
    private var currentAlbum = "YouTube"
    private var interceptedStreams: [String: StreamInfo] = [:] // videoId → stream
    private var pendingContinuations: [String: CheckedContinuation<StreamInfo, Error>] = [:]
    private let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]

    struct StreamInfo {
        let url:      String
        let mimeType: String
        let title:    String
    }

    override init() {
        super.init()
        setupWebView()
    }

    // ── WebView setup ─────────────────────────────────────────────────────
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default() // shares cookies with login

        // Script to intercept YouTube's fetch calls to the player API
        let interceptScript = WKUserScript(source: """
        (function() {
            const originalFetch = window.fetch;
            window.fetch = async function(...args) {
                const response = await originalFetch(...args);
                const url = typeof args[0] === 'string' ? args[0] : args[0]?.url || '';
                if (url.includes('/youtubei/v1/player')) {
                    const clone = response.clone();
                    clone.json().then(data => {
                        const videoId = data?.videoDetails?.videoId;
                        const title   = data?.videoDetails?.title || 'YouTube Track';
                        const formats = data?.streamingData?.adaptiveFormats || [];
                        const audio   = formats.filter(f =>
                            f.mimeType && f.mimeType.startsWith('audio') && f.url
                        ).sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
                        if (audio.length > 0 && videoId) {
                            window.webkit.messageHandlers.streamIntercepted.postMessage({
                                videoId:  videoId,
                                title:    title,
                                url:      audio[0].url,
                                mimeType: audio[0].mimeType.split(';')[0]
                            });
                        }
                    }).catch(() => {});
                }
                return response;
            };

            // Also intercept XMLHttpRequest for older YouTube code paths
            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                this._url = url;
                return origOpen.call(this, method, url, ...rest);
            };
            XMLHttpRequest.prototype.send = function(body) {
                if (this._url && this._url.includes('/youtubei/v1/player')) {
                    this.addEventListener('load', function() {
                        try {
                            const data = JSON.parse(this.responseText);
                            const videoId = data?.videoDetails?.videoId;
                            const title   = data?.videoDetails?.title || 'YouTube Track';
                            const formats = data?.streamingData?.adaptiveFormats || [];
                            const audio   = formats.filter(f =>
                                f.mimeType && f.mimeType.startsWith('audio') && f.url
                            ).sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
                            if (audio.length > 0 && videoId) {
                                window.webkit.messageHandlers.streamIntercepted.postMessage({
                                    videoId:  videoId,
                                    title:    title,
                                    url:      audio[0].url,
                                    mimeType: audio[0].mimeType.split(';')[0]
                                });
                            }
                        } catch(e) {}
                    });
                }
                return origSend.call(this, body);
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

        config.userContentController.add(self, name: "streamIntercepted")
        config.userContentController.addUserScript(interceptScript)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
    }

    // ── WKScriptMessageHandler — receives intercepted stream data ─────────
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "streamIntercepted",
              let body     = message.body as? [String: Any],
              let videoId  = body["videoId"]  as? String,
              let urlStr   = body["url"]       as? String,
              let mime     = body["mimeType"]  as? String,
              let title    = body["title"]     as? String
        else { return }

        let stream = StreamInfo(url: urlStr, mimeType: mime, title: title)
        Task { @MainActor in
            self.interceptedStreams[videoId] = stream
            if let cont = self.pendingContinuations[videoId] {
                cont.resume(returning: stream)
                self.pendingContinuations.removeValue(forKey: videoId)
            }
        }
    }

    // ── Entry point ───────────────────────────────────────────────────────
    func start(urlString: String) {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()

        Task {
            do {
                if let listId = extractPlaylistId(from: urlString),
                   !urlString.contains("watch?v=") {
                    try await downloadPlaylist(listId: listId, originalURL: urlString)
                } else if let videoId = extractVideoId(from: urlString) {
                    try await downloadSingleVideo(videoId: videoId, album: "YouTube")
                } else {
                    addItem("Error", status: .error, message: "Could not find video or playlist ID")
                }
            } catch {
                addItem("Error", status: .error, message: error.localizedDescription)
            }
            isDownloading = false
            LibraryManager.shared.reload()
        }
    }

    // ── Playlist ──────────────────────────────────────────────────────────
    private func downloadPlaylist(listId: String, originalURL: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist…")

        // Use InnerTube browse (no PO token needed for metadata)
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20231121.08.00"]]
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw dlErr("Could not parse playlist")
        }

        var name = "YouTube Playlist"
        if let h = json["header"] as? [String: Any],
           let r = h["playlistHeaderRenderer"] as? [String: Any],
           let t = r["title"] as? [String: Any],
           let runs = t["runs"] as? [[String: Any]] {
            name = runs.first?["text"] as? String ?? name
        }

        var videoIds: [String] = []
        extractVideoIds(from: json, into: &videoIds)

        guard !videoIds.isEmpty else { throw dlErr("No videos found in playlist") }

        updateItem("Playlist", status: .pending,
                   message: "\(name) — \(videoIds.count) tracks")

        for id in videoIds {
            try await downloadSingleVideo(videoId: id, album: name)
        }
    }

    // ── Single video via WebView interception ─────────────────────────────
    private func downloadSingleVideo(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        addItem(key, status: .downloading, message: "Loading…")

        // Get stream by loading the YouTube watch page in the hidden WebView
        // YouTube's own JS runs BotGuard, generates PO token, fetches player API
        // Our injected script intercepts the response and sends us the audio URL
        let stream = try await getStream(for: videoId)

        updateItem(key, newTitle: stream.title, status: .downloading,
                   message: "Downloading…")

        let ext  = stream.mimeType.contains("webm") ? "webm" : "m4a"
        let safe = sanitize(stream.title)
        let albumDir = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(at: albumDir,
                                                  withIntermediateDirectories: true)
        let dest = albumDir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        guard let audioURL = URL(string: stream.url) else {
            throw dlErr("Invalid audio URL")
        }
        let (tmpURL, _) = try await URLSession.shared.download(from: audioURL)
        try FileManager.default.moveItem(at: tmpURL, to: dest)

        let track = Track(id: UUID(), name: stream.title, album: album,
                          filename: "\(sanitize(album))/\(safe).\(ext)",
                          addedAt: Date())
        LibraryManager.shared.add(track)
        updateItem(stream.title, status: .done, message: "Saved ✓")
    }

    // ── Load YouTube watch page and wait for intercepted stream ───────────
    private func getStream(for videoId: String) async throws -> StreamInfo {
        // Check if already intercepted (e.g. from a previous page load)
        if let cached = interceptedStreams[videoId] { return cached }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[videoId] = continuation

            let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
            webView?.load(URLRequest(url: url))

            // Timeout after 30s
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    if let cont = self.pendingContinuations[videoId] {
                        cont.resume(throwing: self.dlErr("Timed out loading video \(videoId)"))
                        self.pendingContinuations.removeValue(forKey: videoId)
                    }
                }
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────
    private func extractVideoIds(from obj: Any, into ids: inout [String]) {
        if let dict = obj as? [String: Any] {
            if let r = dict["playlistVideoRenderer"] as? [String: Any],
               let v = r["videoId"] as? String, !ids.contains(v) { ids.append(v) }
            dict.values.forEach { extractVideoIds(from: $0, into: &ids) }
        } else if let arr = obj as? [Any] {
            arr.forEach { extractVideoIds(from: $0, into: &ids) }
        }
    }

    private func extractVideoId(from url: String) -> String? {
        guard let r  = url.range(of: "(?:v=|youtu\\.be/|/embed/)([A-Za-z0-9_-]{11})",
                                  options: .regularExpression),
              let vr = url[r].range(of: "[A-Za-z0-9_-]{11}", options: .regularExpression)
        else { return nil }
        return String(url[r][vr])
    }

    private func extractPlaylistId(from url: String) -> String? {
        guard let r = url.range(of: "[?&]list=([A-Za-z0-9_-]+)",
                                 options: .regularExpression)
        else { return nil }
        return String(url[r]).components(separatedBy: "list=").last?
                              .components(separatedBy: "&").first
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
         .trimmingCharacters(in: .whitespaces)
    }

    private func dlErr(_ msg: String) -> NSError {
        NSError(domain: "Download", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func addItem(_ title: String, status: DLStatus, message: String) {
        items.append(DLItem(title: title, status: status, message: message))
    }

    private func updateItem(_ title: String, newTitle: String? = nil,
                            status: DLStatus, message: String) {
        guard let i = items.firstIndex(where: { $0.title == title }) else { return }
        items[i].status  = status
        items[i].message = message
        if let t = newTitle { items[i].title = t }
    }
}

// ── WKNavigationDelegate ──────────────────────────────────────────────────────
extension DownloadManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in
            // Fail all pending continuations
            for (id, cont) in self.pendingContinuations {
                cont.resume(throwing: error)
            }
            self.pendingContinuations.removeAll()
        }
    }
}