import Foundation
import WebKit
import Combine
import UniformTypeIdentifiers
import UIKit

// DownloadManager
// Download priority order:
//   1. Proxy server  -- if ServerManager.shared.isConnected && hasYtdlp
//      Sends URL to /api/fetch, server yt-dlp downloads + streams bytes back,
//      deletes temp file. No storage on server -- works on Render free tier.
//   2. InnerTube ANDROID client -- direct API, no WebView needed
//   3. WebView fallback -- original embed-page approach

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

    // MARK: - WebView (lazy)

    private func ensureWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = .all
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

    // MARK: - Public entry point

    func start(urlString: String) {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()

        Task {
            do {
                let srv = ServerManager.shared
                if srv.isConnected && srv.hasYtdlp {
                    try await downloadViaServer(urlString: urlString,
                                                serverBase: srv.base)
                } else {
                    if let listId = extractPlaylistId(from: urlString),
                       !urlString.contains("watch?v=") {
                        try await downloadPlaylist(listId: listId)
                    } else if let videoId = extractVideoId(from: urlString) {
                        try await downloadVideo(videoId: videoId, album: "YouTube")
                    } else {
                        addItem("Error", status: .error,
                                message: "No video or playlist ID found")
                    }
                }
            } catch {
                addItem("Error", status: .error, message: error.localizedDescription)
            }
            isDownloading = false
            LibraryManager.shared.reload()
        }
    }

    // MARK: - PATH 1: Proxy server (/api/fetch)
    // Server downloads via yt-dlp into a temp file, streams bytes back,
    // then deletes the temp file. No persistent storage on the server.

    private func downloadViaServer(urlString: String, serverBase: String) async throws {
        // Playlists: extract IDs client-side, then download each track through server
        if let listId = extractPlaylistId(from: urlString),
           !urlString.contains("watch?v=") {
            try await downloadPlaylistViaServer(listId: listId, serverBase: serverBase)
            return
        }

        // Single video
        addItem("Track", status: .downloading, message: "Server is processing...")
        try await fetchOneViaServer(youtubeURL: urlString,
                                    placeholderTitle: "Track",
                                    album: "YouTube",
                                    serverBase: serverBase)
    }

    // Playlist via server: resolve IDs client-side, download each via /api/fetch
    private func downloadPlaylistViaServer(listId: String, serverBase: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist info...")
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20231121.08.00"]]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw dlErr("Could not parse playlist") }

        var name = "YouTube Playlist"
        if let h    = json["header"]              as? [String: Any],
           let r    = h["playlistHeaderRenderer"] as? [String: Any],
           let t    = r["title"]                  as? [String: Any],
           let runs = t["runs"]                   as? [[String: Any]] {
            name = runs.first?["text"] as? String ?? name
        }
        var ids: [String] = []
        extractVideoIds(from: json, into: &ids)
        guard !ids.isEmpty else { throw dlErr("No videos found in playlist") }

        updateItem("Playlist", status: .pending,
                   message: "\(name) -- \(ids.count) tracks")

        for (i, videoId) in ids.enumerated() {
            let ytURL = "https://www.youtube.com/watch?v=\(videoId)"
            let placeholder = "Track \(i + 1) of \(ids.count)"
            addItem(placeholder, status: .downloading,
                    message: "\(i + 1) / \(ids.count) -- server")
            do {
                try await fetchOneViaServer(youtubeURL: ytURL,
                                            placeholderTitle: placeholder,
                                            album: name,
                                            serverBase: ServerManager.shared.base)
            } catch {
                updateItem(placeholder, status: .error,
                           message: error.localizedDescription)
            }
        }
    }

    /// Hit /api/fetch?url=..., receive the audio file, save it.
    private func fetchOneViaServer(youtubeURL: String,
                                   placeholderTitle: String,
                                   album: String,
                                   serverBase: String) async throws {
        let encoded = youtubeURL.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? youtubeURL
        guard let endpoint = URL(string: "\(serverBase)/api/fetch?url=\(encoded)")
        else { throw dlErr("Invalid server URL") }

        // 180s timeout -- free tier servers cold-start in ~30s
        var req = URLRequest(url: endpoint, timeoutInterval: 180)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let session = serverBase.hasPrefix("https")
            ? ServerManager.shared.localSession : URLSession.shared

        updateItem(placeholderTitle, status: .downloading,
                   message: "Downloading via server...")

        let (tmp, resp) = try await session.download(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw dlErr("No HTTP response from server")
        }
        if http.statusCode != 200 {
            let body = (try? String(contentsOf: tmp)) ?? ""
            if let d = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let msg  = json["error"] as? String { throw dlErr(msg) }
            throw dlErr("Server error: HTTP \(http.statusCode)")
        }

        // Server returns real title + ext in response headers
        let rawTitle = http.value(forHTTPHeaderField: "X-Track-Title") ?? placeholderTitle
        let ext      = http.value(forHTTPHeaderField: "X-Track-Ext")   ?? "m4a"
        let title    = rawTitle.removingPercentEncoding ?? rawTitle

        let safe     = sanitize(title)
        let albumDir = sanitize(album)
        let dir      = docs.appendingPathComponent(albumDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)

        if title != placeholderTitle {
            updateItem(placeholderTitle, newTitle: title, status: .done, message: "Saved")
        } else {
            updateItem(title, status: .done, message: "Saved")
        }

        LibraryManager.shared.add(Track(
            id: UUID(), name: title, album: album,
            filename: "\(albumDir)/\(safe).\(ext)",
            addedAt: Date()))
    }

    // MARK: - PATH 2: InnerTube ANDROID client (no PO token needed)

    private func downloadVideoInnerTube(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        addItem(key, status: .downloading, message: "Fetching stream info...")

        guard let apiURL = URL(string:
            "https://www.youtube.com/youtubei/v1/player" +
            "?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false")
        else { throw dlErr("Bad API URL") }

        var req = URLRequest(url: apiURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(
            "com.google.android.youtube/17.31.35 (Linux; U; Android 11) gzip",
            forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": videoId,
            "context": [
                "client": [
                    "clientName":        "ANDROID",
                    "clientVersion":     "17.31.35",
                    "androidSdkVersion": 30,
                    "hl": "en", "gl": "US"
                ]
            ]
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200
        else { throw dlErr("InnerTube HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw dlErr("Unparseable response") }

        if let ps     = json["playabilityStatus"] as? [String: Any],
           let status = ps["status"] as? String, status != "OK" {
            throw dlErr(ps["reason"] as? String ?? status)
        }

        let title = (json["videoDetails"] as? [String: Any])?["title"]
                    as? String ?? "YouTube Track"

        guard let sd = json["streamingData"] as? [String: Any]
        else { throw dlErr("No streamingData") }

        let adaptive = sd["adaptiveFormats"] as? [[String: Any]] ?? []
        let regular  = sd["formats"]         as? [[String: Any]] ?? []

        let audioFmts = (adaptive + regular).filter { f in
            guard let mime = f["mimeType"] as? String else { return false }
            return mime.hasPrefix("audio") && f["url"] != nil
        }.sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }

        guard let best     = audioFmts.first,
              let streamURL = best["url"]      as? String,
              let mimeType  = best["mimeType"] as? String
        else { throw dlErr("No audio streams from InnerTube") }

        updateItem(key, newTitle: title, status: .downloading, message: "Downloading...")

        let ext  = mimeType.contains("webm") ? "webm" : "m4a"
        let safe = sanitize(title)
        let dir  = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        guard let audioURL = URL(string: streamURL) else { throw dlErr("Bad URL") }
        let (tmp, _) = try await URLSession.shared.download(from: audioURL)
        try FileManager.default.moveItem(at: tmp, to: dest)

        LibraryManager.shared.add(Track(
            id: UUID(), name: title, album: album,
            filename: "\(sanitize(album))/\(safe).\(ext)",
            addedAt: Date()))
        updateItem(title, status: .done, message: "Saved")
    }

    // MARK: - PATH 3: WebView fallback

    private func downloadVideoWebView(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        if items.first(where: { $0.title == key }) != nil {
            updateItem(key, status: .downloading, message: "WebView fallback...")
        } else {
            addItem(key, status: .downloading, message: "Loading YouTube...")
        }

        let stream = try await withCheckedThrowingContinuation { cont in
            pendingContinuations[videoId] = cont
            let url = URL(string: "https://www.youtube.com/embed/\(videoId)?autoplay=0&hl=en")!
            var req = URLRequest(url: url)
            req.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            webView?.load(req)
            Task {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await MainActor.run {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr("Timed out"))
                    }
                }
            }
        }

        updateItem(key, newTitle: stream.title, status: .downloading,
                   message: "Downloading...")

        let ext  = stream.mimeType.contains("webm") ? "webm" : "m4a"
        let safe = sanitize(stream.title)
        let dir  = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)

        guard let audioURL = URL(string: stream.url) else { throw dlErr("Bad URL") }
        let (tmp, _) = try await URLSession.shared.download(from: audioURL)
        try FileManager.default.moveItem(at: tmp, to: dest)

        LibraryManager.shared.add(Track(
            id: UUID(), name: stream.title, album: album,
            filename: "\(sanitize(album))/\(safe).\(ext)",
            addedAt: Date()))
        updateItem(stream.title, status: .done, message: "Saved")
    }

    // Orchestrator: InnerTube -> WebView
    private func downloadVideo(videoId: String, album: String) async throws {
        do {
            try await downloadVideoInnerTube(videoId: videoId, album: album)
        } catch {
            let key = "vid_\(videoId)"
            updateItem(key, status: .downloading,
                       message: "InnerTube failed, trying WebView...")
            ensureWebView()
            try await downloadVideoWebView(videoId: videoId, album: album)
        }
    }

    // MARK: - Playlist (on-device)

    private func downloadPlaylist(listId: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist...")
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20231121.08.00"]]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw dlErr("Could not parse playlist") }

        var name = "YouTube Playlist"
        if let h    = json["header"]              as? [String: Any],
           let r    = h["playlistHeaderRenderer"] as? [String: Any],
           let t    = r["title"]                  as? [String: Any],
           let runs = t["runs"]                   as? [[String: Any]] {
            name = runs.first?["text"] as? String ?? name
        }
        var ids: [String] = []
        extractVideoIds(from: json, into: &ids)
        guard !ids.isEmpty else { throw dlErr("No videos found in playlist") }
        updateItem("Playlist", status: .pending, message: "\(name) -- \(ids.count) tracks")
        for id in ids { try await downloadVideo(videoId: id, album: name) }
    }

    // MARK: - WebView JS extraction

    func extractStreamFromPage(videoId: String, attempt: Int = 0) {
        let js = """
        (function() {
            var data = null;
            if (window.yt && window.yt.playerConfig) {
                var args = window.yt.playerConfig.args || {};
                if (args.player_response) {
                    try { data = JSON.parse(args.player_response); } catch(e) {}
                }
            }
            if (!data) data = window.ytInitialPlayerResponse;
            if (!data) {
                var scripts = document.querySelectorAll('script');
                for (var i = 0; i < scripts.length; i++) {
                    var t = scripts[i].textContent;
                    var idx = t.indexOf('ytInitialPlayerResponse');
                    if (idx >= 0) {
                        try {
                            var start = t.indexOf('{', idx);
                            var depth = 0, end = start;
                            for (; end < Math.min(t.length, start + 500000); end++) {
                                if (t[end] === '{') depth++;
                                else if (t[end] === '}') { depth--; if (depth === 0) break; }
                            }
                            data = JSON.parse(t.substring(start, end + 1));
                            if (data && data.streamingData) break;
                        } catch(e) {}
                    }
                }
            }
            if (!data) return JSON.stringify({error: 'not_ready'});
            var title   = (data.videoDetails || {}).title || 'YouTube Track';
            var sd      = data.streamingData || {};
            var formats = (sd.adaptiveFormats || []).concat(sd.formats || []);
            var audio   = formats
                .filter(function(f){ return f.mimeType && f.mimeType.indexOf('audio') === 0 && f.url; })
                .sort(function(a,b){ return (b.bitrate||0)-(a.bitrate||0); });
            if (audio.length === 0) {
                return JSON.stringify({
                    error: 'No audio streams. Status: ' +
                        ((data.playabilityStatus||{}).status||'unknown') +
                        ' Formats: ' + formats.length
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

        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard let jsonStr  = result as? String,
                      let jsonData = jsonStr.data(using: .utf8),
                      let json     = try? JSONSerialization.jsonObject(with: jsonData)
                                     as? [String: Any] else {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr("JS evaluation failed"))
                    }
                    return
                }
                if let errMsg = json["error"] as? String {
                    if errMsg == "not_ready" && attempt < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.extractStreamFromPage(videoId: videoId, attempt: attempt + 1)
                        }
                        return
                    }
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
                if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                    c.resume(returning: StreamInfo(url: url, mimeType: mime, title: title))
                }
            }
        }
    }

    // MARK: - Local file import

    func importLocalFiles(_ urls: [URL], album: String = "Local") {
        Task {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                let name = url.deletingPathExtension().lastPathComponent
                let ext  = url.pathExtension.lowercased()
                let safe = sanitize(name)
                addItem(name, status: .downloading, message: "Importing...")

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
                    updateItem(name, status: .done, message: "Imported")
                } catch {
                    updateItem(name, status: .error, message: error.localizedDescription)
                }
            }
            LibraryManager.shared.reload()
        }
    }

    // MARK: - Helpers

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
        items[i].status  = status
        items[i].message = message
        if let t = newTitle { items[i].title = t }
    }
}

// MARK: - Weak retain wrapper

class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: DownloadManager?
    init(target: DownloadManager) { self.target = target }
    func userContentController(_ c: WKUserContentController,
                               didReceive msg: WKScriptMessage) {}
}

// MARK: - WKNavigationDelegate

extension DownloadManager: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        guard let urlStr = wv.url?.absoluteString else { return }
        let videoId: String?
        if urlStr.contains("/embed/") {
            videoId = urlStr.components(separatedBy: "/embed/").last?
                            .components(separatedBy: "?").first
        } else {
            videoId = urlStr.components(separatedBy: "v=").last?
                            .components(separatedBy: "&").first
        }
        guard let vid = videoId, vid.count == 11 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.extractStreamFromPage(videoId: vid, attempt: 0)
        }
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