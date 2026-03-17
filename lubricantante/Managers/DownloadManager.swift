import Foundation
import WebKit
import Combine
import UniformTypeIdentifiers
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// DownloadManager
// Two download paths:
//   1. YouTube: loads watch page in WKWebView, extracts ytInitialPlayerResponse
//   2. Local files: imports from Files app or Camera Roll
// ─────────────────────────────────────────────────────────────────────────────

enum DLStatus { case pending, downloading, done, error }

struct DLItem: Identifiable {
    let id      = UUID()
    var title:   String
    var status:  DLStatus
    var message: String
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var items: [DLItem] = []
    @Published var isDownloading   = false

    private var webView: WKWebView?
    private var pendingContinuations: [String: CheckedContinuation<StreamInfo, Error>] = [:]
    private let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]

    struct StreamInfo {
        let url: String; let mimeType: String; let title: String
    }

    override init() { super.init() }

    // Called lazily on first download — UI is guaranteed ready by then
    private func ensureWebView() {
        guard webView == nil else { return }
        setupWebView()
    }

    // ── WebView setup ─────────────────────────────────────────────────────
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = .all

        // Message handler to receive stream info from JS
        config.userContentController.add(
            WeakScriptHandler(target: self), name: "streamReady")

        let wv = WKWebView(frame: CGRect(x: -2, y: -2, width: 1, height: 1),
                           configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.addSubview(wv)
        }
        self.webView = wv
    }

    // ── Entry point: YouTube ──────────────────────────────────────────────
    func start(urlString: String) {
        guard !isDownloading else { return }
        isDownloading = true; items.removeAll()
        ensureWebView()
        Task {
            do {
                if let listId = extractPlaylistId(from: urlString),
                   !urlString.contains("watch?v=") {
                    try await downloadPlaylist(listId: listId)
                } else if let videoId = extractVideoId(from: urlString) {
                    try await downloadVideo(videoId: videoId, album: "YouTube")
                } else {
                    addItem("Error", status: .error, message: "No video or playlist ID found")
                }
            } catch { addItem("Error", status: .error, message: error.localizedDescription) }
            isDownloading = false
            LibraryManager.shared.reload()
        }
    }

    // ── Playlist metadata via InnerTube browse (no PO token needed) ───────
    private func downloadPlaylist(listId: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist…")
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20231121.08.00"]]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { throw dlErr("Could not parse playlist") }

        var name = "YouTube Playlist"
        if let h = json["header"] as? [String: Any],
           let r = h["playlistHeaderRenderer"] as? [String: Any],
           let t = r["title"] as? [String: Any],
           let runs = t["runs"] as? [[String: Any]] {
            name = runs.first?["text"] as? String ?? name
        }
        var ids: [String] = []
        extractVideoIds(from: json, into: &ids)
        guard !ids.isEmpty else { throw dlErr("No videos found in playlist") }
        updateItem("Playlist", status: .pending,
                   message: "\(name) — \(ids.count) tracks")
        for id in ids { try await downloadVideo(videoId: id, album: name) }
    }

    // ── Single video: load in WebView, extract ytInitialPlayerResponse ────
    private func downloadVideo(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        addItem(key, status: .downloading, message: "Loading YouTube…")

        let stream = try await withCheckedThrowingContinuation { cont in
            pendingContinuations[videoId] = cont
            // Load mobile YouTube — it populates ytInitialPlayerResponse synchronously
            let url = URL(string: "https://m.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1")!
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
            webView?.load(req)

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await MainActor.run {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr("Timed out — try again or check internet"))
                    }
                }
            }
        }

        updateItem(key, newTitle: stream.title, status: .downloading,
                   message: "Downloading audio…")

        let ext  = stream.mimeType.contains("webm") ? "webm" : "m4a"
        let safe = sanitize(stream.title)
        let dir  = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        guard let audioURL = URL(string: stream.url) else { throw dlErr("Bad URL") }
        let (tmp, _) = try await URLSession.shared.download(from: audioURL)
        try FileManager.default.moveItem(at: tmp, to: dest)

        LibraryManager.shared.add(Track(id: UUID(), name: stream.title, album: album,
            filename: "\(sanitize(album))/\(safe).\(ext)", addedAt: Date()))
        updateItem(stream.title, status: .done, message: "Saved ✓")
    }

    // ── Called by WKNavigationDelegate after page finishes loading ────────
    func extractStreamFromPage(videoId: String) {
        let js = """
        (function() {
            // Try ytInitialPlayerResponse first (set synchronously on page load)
            var data = window.ytInitialPlayerResponse;

            // Fallback: search inline scripts for the JSON
            if (!data) {
                var scripts = document.querySelectorAll('script');
                for (var i = 0; i < scripts.length; i++) {
                    var t = scripts[i].textContent;
                    var idx = t.indexOf('ytInitialPlayerResponse');
                    if (idx >= 0) {
                        try {
                            var start = t.indexOf('{', idx);
                            // Find matching closing brace
                            var depth = 0, end = start;
                            for (; end < Math.min(t.length, start + 500000); end++) {
                                if (t[end] === '{') depth++;
                                else if (t[end] === '}') { depth--; if (depth === 0) break; }
                            }
                            data = JSON.parse(t.substring(start, end + 1));
                            break;
                        } catch(e) {}
                    }
                }
            }

            if (!data) return JSON.stringify({error: 'ytInitialPlayerResponse not found'});

            var title = (data.videoDetails || {}).title || 'YouTube Track';
            var formats = (data.streamingData || {}).adaptiveFormats || [];
            var audio = formats
                .filter(function(f){ return f.mimeType && f.mimeType.indexOf('audio') === 0 && f.url; })
                .sort(function(a,b){ return (b.bitrate||0)-(a.bitrate||0); });

            if (audio.length === 0) {
                return JSON.stringify({
                    error: 'No audio streams. Status: ' +
                        ((data.playabilityStatus||{}).status||'unknown') +
                        ' Reason: ' + ((data.playabilityStatus||{}).reason||'none')
                });
            }

            return JSON.stringify({
                videoId: (data.videoDetails||{}).videoId || '',
                title:   title,
                url:     audio[0].url,
                mime:    audio[0].mimeType.split(';')[0]
            });
        })();
        """

        webView?.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            Task { @MainActor in
                guard let jsonStr = result as? String,
                      let jsonData = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData)
                                  as? [String: Any] else {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr("JS evaluation failed"))
                    }
                    return
                }

                if let errMsg = json["error"] as? String {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr(errMsg))
                    }
                    return
                }

                guard let url   = json["url"]   as? String,
                      let title = json["title"] as? String,
                      let mime  = json["mime"]  as? String else {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr("Missing stream fields"))
                    }
                    return
                }

                let stream = StreamInfo(url: url, mimeType: mime, title: title)
                if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                    c.resume(returning: stream)
                }
            }
        }
    }

    // ── Local file import ─────────────────────────────────────────────────
    func importLocalFiles(_ urls: [URL], album: String = "Local") {
        Task {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                let name = url.deletingPathExtension().lastPathComponent
                let ext  = url.pathExtension.lowercased()
                let safe = sanitize(name)

                addItem(name, status: .downloading, message: "Importing…")

                do {
                    let dir  = docs.appendingPathComponent(sanitize(album))
                    try? FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent("\(safe).\(ext)")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)

                    LibraryManager.shared.add(Track(
                        id: UUID(), name: name, album: album,
                        filename: "\(sanitize(album))/\(safe).\(ext)",
                        addedAt: Date()))
                    updateItem(name, status: .done, message: "Imported ✓")
                } catch {
                    updateItem(name, status: .error, message: error.localizedDescription)
                }
            }
            LibraryManager.shared.reload()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────
    private func extractVideoIds(from obj: Any, into ids: inout [String]) {
        if let d = obj as? [String: Any] {
            if let r = d["playlistVideoRenderer"] as? [String: Any],
               let v = r["videoId"] as? String, !ids.contains(v) { ids.append(v) }
            d.values.forEach { extractVideoIds(from: $0, into: &ids) }
        } else if let a = obj as? [Any] { a.forEach { extractVideoIds(from: $0, into: &ids) } }
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

    private func dlErr(_ m: String) -> NSError {
        NSError(domain: "DL", code: 0, userInfo: [NSLocalizedDescriptionKey: m])
    }

    private func addItem(_ title: String, status: DLStatus, message: String) {
        items.append(DLItem(title: title, status: status, message: message))
    }

    private func updateItem(_ title: String, newTitle: String? = nil,
                            status: DLStatus, message: String) {
        guard let i = items.firstIndex(where: { $0.title == title }) else { return }
        items[i].status = status; items[i].message = message
        if let t = newTitle { items[i].title = t }
    }
}

// ── Weak reference wrapper to avoid retain cycle in WKUserContentController ──
class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: DownloadManager?
    init(target: DownloadManager) { self.target = target }
    func userContentController(_ c: WKUserContentController,
                               didReceive msg: WKScriptMessage) {}
}

// ── WKNavigationDelegate ──────────────────────────────────────────────────────
extension DownloadManager: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        guard let urlStr = wv.url?.absoluteString,
              let videoId = urlStr.components(separatedBy: "v=").last?
                                   .components(separatedBy: "&").first,
              videoId.count == 11 else { return }
        Task { @MainActor in self.extractStreamFromPage(videoId: videoId) }
    }

    nonisolated func webView(_ wv: WKWebView, didFail nav: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in
            for (_, cont) in self.pendingContinuations { cont.resume(throwing: error) }
            self.pendingContinuations.removeAll()
        }
    }

    nonisolated func webView(_ wv: WKWebView,
                              didFailProvisionalNavigation nav: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in
            for (_, cont) in self.pendingContinuations { cont.resume(throwing: error) }
            self.pendingContinuations.removeAll()
        }
    }
}