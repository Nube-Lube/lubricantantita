import Foundation
import WebKit
import Combine
import UniformTypeIdentifiers
import UIKit
import PhotosUI
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
// DownloadManager
// YouTube: injects script at document start to grab stream data the moment
//          YouTube's inline scripts set ytInitialPlayerResponse
// Local:   imports from Files app or Camera Roll (converts video to audio)
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

    @Published var items:         [DLItem] = []
    @Published var isDownloading: Bool     = false

    private var webView:              WKWebView?
    private var pendingContinuations: [String: CheckedContinuation<StreamInfo, Error>] = [:]
    private let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]

    struct StreamInfo { let url: String; let mimeType: String; let title: String }

    override init() { super.init() }

    // ── Lazy WebView setup (called on first download) ─────────────────────
    private func ensureWebView() {
        guard webView == nil else { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = .all

        // Inject at document start — fires before ANY page JS runs
        // Overrides Object.defineProperty so we intercept when YouTube sets
        // ytInitialPlayerResponse on the window object
        let inject = """
        (function() {
            var _ytpr = null;
            function tryPost(val) {
                if (!val || !val.videoDetails || !val.streamingData) return false;
                var title   = (val.videoDetails||{}).title || 'YouTube Track';
                var sd      = val.streamingData || {};
                var formats = (sd.adaptiveFormats||[]).concat(sd.formats||[]);
                var audio   = formats
                    .filter(function(f){
                        return f.mimeType && f.mimeType.indexOf('audio')===0 && f.url;
                    })
                    .sort(function(a,b){return (b.bitrate||0)-(a.bitrate||0);});
                if (audio.length === 0) return false;
                try {
                    window.webkit.messageHandlers.ytStream.postMessage({
                        videoId:  (val.videoDetails||{}).videoId || '',
                        title:    title,
                        url:      audio[0].url,
                        mimeType: audio[0].mimeType.split(';')[0]
                    });
                } catch(e) {}
                return true;
            }

            // Intercept ytInitialPlayerResponse being set on window
            try {
                Object.defineProperty(window, 'ytInitialPlayerResponse', {
                    get: function() { return _ytpr; },
                    set: function(val) {
                        _ytpr = val;
                        tryPost(val);
                    },
                    configurable: true
                });
            } catch(e) {}

            // Also intercept yt.setConfig which embed pages use
            var _yt = {};
            try {
                Object.defineProperty(window, 'yt', {
                    get: function() { return _yt; },
                    set: function(val) {
                        _yt = val;
                        if (val && val.playerConfig) {
                            var args = val.playerConfig.args || {};
                            if (args.player_response) {
                                try { tryPost(JSON.parse(args.player_response)); } catch(e) {}
                            }
                        }
                    },
                    configurable: true
                });
            } catch(e) {}

            // Intercept fetch as final fallback
            var origFetch = window.fetch;
            window.fetch = function() {
                var args = arguments;
                return origFetch.apply(this, args).then(function(res) {
                    var url = (typeof args[0]==='string'?args[0]:args[0]&&args[0].url)||'';
                    if (url.indexOf('/youtubei/v1/player') >= 0) {
                        res.clone().json().then(tryPost).catch(function(){});
                    }
                    return res;
                });
            };
        })();
        """

        let script = WKUserScript(source: inject,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(WeakHandler(target: self), name: "ytStream")

        let wv = WKWebView(frame: CGRect(x: -2, y: -2, width: 1, height: 1),
                           configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        wv.alpha = 0.001

        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.addSubview(wv)
        }
        self.webView = wv
    }

    // ── Message received from injected JS ─────────────────────────────────
    func handleStreamMessage(_ body: [String: Any]) {
        guard let videoId = body["videoId"] as? String,
              let url     = body["url"]     as? String,
              let title   = body["title"]   as? String,
              let mime    = body["mimeType"] as? String,
              !url.isEmpty else { return }

        let stream = StreamInfo(url: url, mimeType: mime, title: title)
        if let cont = pendingContinuations.removeValue(forKey: videoId) {
            cont.resume(returning: stream)
        }
    }

    // ── Entry point: YouTube ──────────────────────────────────────────────
    func start(urlString: String) {
        guard !isDownloading else { return }
        isDownloading = true
        items.removeAll()
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
            } catch {
                addItem("Error", status: .error, message: error.localizedDescription)
            }
            isDownloading = false
            LibraryManager.shared.reload()
        }
    }

    // ── Playlist metadata via InnerTube browse ────────────────────────────
    private func downloadPlaylist(listId: String) async throws {
        addItem("Playlist", status: .downloading, message: "Fetching playlist…")
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "VL\(listId)",
            "context": ["client": [
                "clientName": "WEB", "clientVersion": "2.20231121.08.00"]]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { throw dlErr("Could not parse playlist") }

        var name = "YouTube Playlist"
        if let h    = json["header"] as? [String: Any],
           let r    = h["playlistHeaderRenderer"] as? [String: Any],
           let t    = r["title"] as? [String: Any],
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

    // ── Single video ──────────────────────────────────────────────────────
    private func downloadVideo(videoId: String, album: String) async throws {
        let key = "vid_\(videoId)"
        addItem(key, status: .downloading, message: "Loading…")

        let stream = try await withCheckedThrowingContinuation { cont in
            pendingContinuations[videoId] = cont

            // Load watch page — injected script intercepts ytInitialPlayerResponse
            let url = URL(string:
                "https://www.youtube.com/watch?v=\(videoId)&has_verified=1")!
            webView?.load(URLRequest(url: url))

            // Timeout after 30s
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    if let c = self.pendingContinuations.removeValue(forKey: videoId) {
                        c.resume(throwing: self.dlErr(
                            "Timed out — make sure you're signed in to YouTube"))
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

    // ── Local file import (Files app) ─────────────────────────────────────
    func importLocalFiles(_ urls: [URL], album: String = "Local") {
        Task {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                await importSingleFile(url: url, album: album)
            }
            LibraryManager.shared.reload()
        }
    }

    // ── Camera Roll import (converts video to audio via AVAssetExportSession)
    func importFromCameraRoll(_ items: [PHPickerResult], album: String = "Camera Roll") {
        Task {
            for item in items {
                let name = "Video \(Int(Date().timeIntervalSince1970))"
                addItem(name, status: .downloading, message: "Loading from Camera Roll…")

                do {
                    let url = try await loadPHPickerItem(item)
                    let ext = url.pathExtension.lowercased()
                    let isVideo = ["mp4","mov","m4v","avi"].contains(ext)

                    if isVideo {
                        updateItem(name, status: .downloading, message: "Converting to audio…")
                        let audioURL = try await extractAudioFromVideo(url,
                                                                        title: name,
                                                                        album: album)
                        let trackName = audioURL.deletingPathExtension().lastPathComponent
                        LibraryManager.shared.add(Track(
                            id: UUID(), name: trackName, album: album,
                            filename: "\(sanitize(album))/\(audioURL.lastPathComponent)",
                            addedAt: Date()))
                        updateItem(name, newTitle: trackName,
                                   status: .done, message: "Converted ✓")
                    } else {
                        await importSingleFile(url: url, album: album)
                    }
                } catch {
                    updateItem(name, status: .error, message: error.localizedDescription)
                }
            }
            LibraryManager.shared.reload()
        }
    }

    private func loadPHPickerItem(_ item: PHPickerResult) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            item.itemProvider.loadFileRepresentation(
                forTypeIdentifier: UTType.movie.identifier
            ) { url, error in
                if let error = error { cont.resume(throwing: error); return }
                guard let url = url else {
                    cont.resume(throwing: self.dlErr("Could not load file")); return
                }
                // Copy to temp since the provided URL is ephemeral
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tmp)
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                    cont.resume(returning: tmp)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // ── Extract audio track from video using AVFoundation ─────────────────
    private func extractAudioFromVideo(_ videoURL: URL,
                                        title: String,
                                        album: String) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let dir   = docs.appendingPathComponent(sanitize(album))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let outputURL = dir.appendingPathComponent("\(sanitize(title)).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A)
        else { throw dlErr("Could not create export session") }

        session.outputURL        = outputURL
        session.outputFileType   = .m4a
        session.timeRange        = CMTimeRange(start: .zero,
                                               duration: try await asset.load(.duration))

        await session.export()

        guard session.status == .completed else {
            throw session.error ?? dlErr("Export failed")
        }
        return outputURL
    }

    // Public wrapper for use from YouTubeView photo import
    func importSingleFilePublic(url: URL, album: String) async {
        await importSingleFile(url: url, album: album)
    }

    // ── Shared file copy logic ────────────────────────────────────────────
    @discardableResult
    private func importSingleFile(url: URL, album: String) async -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension.lowercased()
        let safe = sanitize(name)

        addItem(name, status: .downloading, message: "Importing…")
        do {
            let dir  = docs.appendingPathComponent(sanitize(album))
            try? FileManager.default.createDirectory(at: dir,
                                                      withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(safe).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            LibraryManager.shared.add(Track(
                id: UUID(), name: name, album: album,
                filename: "\(sanitize(album))/\(safe).\(ext)",
                addedAt: Date()))
            updateItem(name, status: .done, message: "Imported ✓")
            return true
        } catch {
            updateItem(name, status: .error, message: error.localizedDescription)
            return false
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────
    private func extractVideoIds(from obj: Any, into ids: inout [String]) {
        if let d = obj as? [String: Any] {
            if let r = d["playlistVideoRenderer"] as? [String: Any],
               let v = r["videoId"] as? String, !ids.contains(v) { ids.append(v) }
            d.values.forEach { extractVideoIds(from: $0, into: &ids) }
        } else if let a = obj as? [Any] {
            a.forEach { extractVideoIds(from: $0, into: &ids) }
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

// ── Weak handler to avoid retain cycle ───────────────────────────────────────
class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: DownloadManager?
    init(target: DownloadManager) { self.target = target }
    nonisolated func userContentController(_ c: WKUserContentController,
                                            didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any] else { return }
        Task { @MainActor in self.target?.handleStreamMessage(body) }
    }
}

// ── WKNavigationDelegate ──────────────────────────────────────────────────────
extension DownloadManager: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFail nav: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in
            self.pendingContinuations.values.forEach { $0.resume(throwing: error) }
            self.pendingContinuations.removeAll()
        }
    }
    nonisolated func webView(_ wv: WKWebView,
                              didFailProvisionalNavigation _: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in
            self.pendingContinuations.values.forEach { $0.resume(throwing: error) }
            self.pendingContinuations.removeAll()
        }
    }
}