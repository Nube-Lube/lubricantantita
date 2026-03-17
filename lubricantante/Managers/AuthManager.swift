import Foundation
import WebKit
import SwiftUI
import Combine

// Handles YouTube login via embedded WebView, extracts auth cookies
// for use in InnerTube API requests — bypasses bot detection entirely.

@MainActor
class AuthManager: NSObject, ObservableObject {
    static let shared = AuthManager()

    @Published var isSignedIn = false
    @Published var userEmail  = ""

    private let defaults  = UserDefaults.standard
    private let cookieKey = "yt_auth_cookies_v2"
    private let emailKey  = "yt_auth_email"

    override init() {
        super.init()
        loadSaved()
    }

    // ── Saved state ───────────────────────────────────────────────────────
    private func loadSaved() {
        userEmail  = defaults.string(forKey: emailKey) ?? ""
        isSignedIn = !userEmail.isEmpty
    }

    func signOut() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: emailKey)
        isSignedIn = false
        userEmail  = ""
        // Clear WKWebView cookies
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
                   .forEach { store.removeData(ofTypes: $0.dataTypes, for: [$0]) { } }
        }
    }

    // ── Cookie extraction ─────────────────────────────────────────────────
    func extractCookies(from webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all   = await store.allCookies()

        // We need SAPISID, __Secure-3PAPISID, and SID cookies at minimum
        let ytCookies = all.filter {
            ["google.com", "youtube.com"].contains($0.domain.hasPrefix(".") ?
                String($0.domain.dropFirst()) : $0.domain)
        }

        guard !ytCookies.isEmpty else { return }

        // Save as serializable dicts
        let saved = ytCookies.map { cookie -> [String: Any] in
            var d: [String: Any] = [
                "name":   cookie.name,
                "value":  cookie.value,
                "domain": cookie.domain,
                "path":   cookie.path,
            ]
            if let exp = cookie.expiresDate { d["expires"] = exp.timeIntervalSince1970 }
            return d
        }
        defaults.set(saved, forKey: cookieKey)

        // Try to get email from cookie or page
        if let emailCookie = ytCookies.first(where: { $0.name == "PREF" }) {
            _ = emailCookie // placeholder
        }

        isSignedIn = true
        if userEmail.isEmpty { userEmail = "Signed in" }
        defaults.set(userEmail, forKey: emailKey)
    }

    // ── Build auth headers for InnerTube requests ─────────────────────────
    func authHeaders() -> [String: String] {
        guard isSignedIn,
              let saved = defaults.array(forKey: cookieKey) as? [[String: Any]]
        else { return [:] }

        let cookieStr = saved
            .compactMap { d -> String? in
                guard let name  = d["name"]  as? String,
                      let value = d["value"] as? String
                else { return nil }
                return "\(name)=\(value)"
            }
            .joined(separator: "; ")

        guard !cookieStr.isEmpty else { return [:] }

        // Build SAPISIDHASH for Authorization header
        var headers: [String: String] = [
            "Cookie": cookieStr,
            "X-Youtube-Client-Name": "1",
            "X-Youtube-Client-Version": "2.20231121.08.00",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/",
        ]

        // Build SAPISIDHASH if SAPISID cookie present
        if let sapisid = saved.first(where: { ($0["name"] as? String) == "SAPISID" })?["value"] as? String {
            let ts   = Int(Date().timeIntervalSince1970)
            let hash = "\(ts) \(sapisid) https://www.youtube.com"
                .data(using: .utf8)!
                .sha1Hex()
            headers["Authorization"] = "SAPISIDHASH \(ts)_\(hash)"
        }

        return headers
    }
}

// ── SHA1 helper ───────────────────────────────────────────────────────────────
import CryptoKit

extension Data {
    func sha1Hex() -> String {
        let digest = Insecure.SHA1.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// ── Login WebView ─────────────────────────────────────────────────────────────
struct YouTubeLoginView: View {
    @ObservedObject var auth = AuthManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var webView = WKWebView()
    @State private var isLoading = true
    @State private var currentURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                WebViewRepresentable(
                    webView:    webView,
                    onURLChange: { url in
                        currentURL = url
                        // Detect successful login
                        if url.contains("youtube.com") && !url.contains("accounts.google") {
                            Task {
                                await auth.extractCookies(from: webView)
                                if auth.isSignedIn {
                                    dismiss()
                                }
                            }
                        }
                    },
                    onLoadFinish: { isLoading = false }
                )

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: "080809"))
                }
            }
            .navigationTitle("Sign in to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color(hex: "c8a96e"))
                }
            }
        }
        .onAppear {
            loadLoginPage()
        }
    }

    private func loadLoginPage() {
        // Load YouTube — if not logged in it redirects to Google login
        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue")!
        webView.load(URLRequest(url: url))
    }
}

// ── WKWebView SwiftUI wrapper ─────────────────────────────────────────────────
struct WebViewRepresentable: UIViewRepresentable {
    let webView:     WKWebView
    let onURLChange: (String) -> Void
    let onLoadFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange, onLoadFinish: onLoadFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let onURLChange:  (String) -> Void
        let onLoadFinish: () -> Void

        init(onURLChange: @escaping (String) -> Void,
             onLoadFinish: @escaping () -> Void) {
            self.onURLChange  = onURLChange
            self.onLoadFinish = onLoadFinish
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            onURLChange(webView.url?.absoluteString ?? "")
            onLoadFinish()
        }
    }
}
