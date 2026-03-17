import SwiftUI
import UniformTypeIdentifiers

struct YouTubeView: View {
    @ObservedObject var dl   = DownloadManager.shared
    @ObservedObject var auth = AuthManager.shared
    @ObservedObject var srv  = ServerManager.shared

    @State private var urlText        = ""
    @State private var showLogin      = false
    @State private var showFilePicker = false
    @State private var albumName      = "Local"
    @State private var showServer     = true    // server section visible by default
    @FocusState private var urlFocused: Bool
    @FocusState private var srvFocused: Bool

    private let supportedTypes: [UTType] = [.audio, .mp3, .wav, .mpeg4Movie, .movie, .video]

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("YouTube")
                    .font(.custom("Georgia", size: 26))
                Spacer()
                // Google auth button (kept for completeness)
                Button {
                    if auth.isSignedIn { auth.signOut() }
                    else { showLogin = true }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(auth.isSignedIn ? Color(hex: "5cac78") : Color(hex: "c45c5c"))
                            .frame(width: 8, height: 8)
                        Text(auth.isSignedIn ? "Signed in" : "Sign in")
                            .font(.custom("Courier New", size: 11))
                            .foregroundColor(auth.isSignedIn ? Color(hex: "5cac78") : Color(hex: "c8a96e"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(hex: "1e1e24")).cornerRadius(99)
                    .overlay(RoundedRectangle(cornerRadius: 99)
                        .stroke(Color.white.opacity(0.07)))
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)

            // ── Server panel ──────────────────────────────────────────────
            serverPanel

            Divider().background(Color.white.opacity(0.06))

            // ── YouTube URL input ─────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("Paste YouTube video or playlist URL…", text: $urlText)
                    .font(.custom("Courier New", size: 12))
                    .foregroundColor(Color(hex: "ede8df"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .focused($urlFocused)
                    .padding(10)
                    .background(Color(hex: "1e1e24"))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(urlFocused ? Color(hex: "c8a96e") : Color.white.opacity(0.07)))

                Button { urlFocused = false; startDownload() } label: {
                    Text(dl.isDownloading ? "…" : "Download")
                        .font(.custom("Courier New", size: 12)).fontWeight(.medium)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(dl.isDownloading ? Color(hex: "1e1e24") : Color(hex: "c8a96e"))
                        .foregroundColor(dl.isDownloading ? Color(hex: "6b6760") : Color(hex: "080809"))
                        .cornerRadius(10)
                }.disabled(dl.isDownloading)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)

            // ── Local import row ──────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("Album name", text: $albumName)
                    .font(.custom("Courier New", size: 12))
                    .foregroundColor(Color(hex: "ede8df"))
                    .padding(8)
                    .background(Color(hex: "1e1e24")).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.07)))
                    .frame(maxWidth: 130)

                Button { showFilePicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 12))
                        Text("Import Files").font(.custom("Courier New", size: 12)).fontWeight(.medium)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(hex: "1e1e24")).foregroundColor(Color(hex: "ede8df"))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.07)))
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            // ── Download list ─────────────────────────────────────────────
            if dl.items.isEmpty {
                EmptyStateView(
                    title: "Nothing yet",
                    subtitle: "Paste a YouTube URL above, or tap Import Files to add local music"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dl.items) { item in
                            DLRow(item: item)
                            Divider().background(Color.white.opacity(0.04)).padding(.leading, 18)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $showLogin)     { YouTubeLoginView() }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(album: albumName, supportedTypes: supportedTypes)
        }
    }

    // ── Server panel view ─────────────────────────────────────────────────
    @ViewBuilder
    private var serverPanel: some View {
        VStack(spacing: 0) {
            // Toggle row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showServer.toggle() }
            } label: {
                HStack(spacing: 8) {
                    // Status dot
                    Circle()
                        .fill(srv.isConnected ? Color(hex: "5cac78") : Color(hex: "444248"))
                        .frame(width: 7, height: 7)

                    Text(srv.isConnected
                         ? "Server: \(srv.trackCount) tracks\(srv.hasYtdlp ? " · yt-dlp ✓" : "")"
                         : "Connect to server.py (optional)")
                        .font(.custom("Courier New", size: 11))
                        .foregroundColor(srv.isConnected ? Color(hex: "5cac78") : Color(hex: "6b6760"))

                    Spacer()

                    Image(systemName: showServer ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "6b6760"))
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color(hex: "111114"))
            }
            .buttonStyle(.plain)

            if showServer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter your server's local IP (shown when you run server.py):")
                        .font(.custom("Courier New", size: 10))
                        .foregroundColor(Color(hex: "6b6760"))

                    HStack(spacing: 8) {
                        TextField("http://192.168.x.x:5000", text: $srv.serverURL)
                            .font(.custom("Courier New", size: 12))
                            .foregroundColor(Color(hex: "ede8df"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .focused($srvFocused)
                            .padding(9)
                            .background(Color(hex: "1e1e24")).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(srvFocused ? Color(hex: "c8a96e") : Color.white.opacity(0.07)))

                        Button {
                            srvFocused = false
                            Task { await srv.ping() }
                        } label: {
                            Group {
                                if srv.isPinging {
                                    ProgressView().scaleEffect(0.7)
                                        .frame(width: 36, height: 36)
                                } else {
                                    Text(srv.isConnected ? "✓" : "Connect")
                                        .font(.custom("Courier New", size: 11)).fontWeight(.medium)
                                        .padding(.horizontal, 10).padding(.vertical, 9)
                                }
                            }
                            .background(srv.isConnected ? Color(hex: "1e3a26") : Color(hex: "1e1e24"))
                            .foregroundColor(srv.isConnected ? Color(hex: "5cac78") : Color(hex: "c8a96e"))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.07)))
                        }
                        .disabled(srv.isPinging || srv.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)

                        if srv.isConnected {
                            Button {
                                srv.serverURL = ""
                                srv.disconnect()
                            } label: {
                                Text("Disconnect")
                                    .font(.custom("Courier New", size: 10))
                                    .foregroundColor(Color(hex: "6b6760"))
                                    .padding(.horizontal, 8).padding(.vertical, 9)
                                    .background(Color(hex: "1e1e24")).cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.07)))
                            }
                        }
                    }

                    // Error or hint
                    if !srv.errorMessage.isEmpty {
                        Text(srv.errorMessage)
                            .font(.custom("Courier New", size: 10))
                            .foregroundColor(Color(hex: "c45c5c"))
                    } else if srv.isConnected {
                        if srv.hasYtdlp {
                            Text("Downloads will use server yt-dlp — faster & more reliable.")
                                .font(.custom("Courier New", size: 10))
                                .foregroundColor(Color(hex: "5cac78"))
                        } else {
                            Text("Connected but yt-dlp not installed. Run: pip install yt-dlp on the server.")
                                .font(.custom("Courier New", size: 10))
                                .foregroundColor(Color(hex: "c8a96e"))
                        }
                    } else {
                        Text("When connected, downloads use server.py's yt-dlp on your Mac/PC, then transfer the file to your iPhone over WiFi.")
                            .font(.custom("Courier New", size: 10))
                            .foregroundColor(Color(hex: "444248"))
                            .lineSpacing(3)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 12).padding(.top, 4)
                .background(Color(hex: "0e0e12"))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func startDownload() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http") else { return }
        dl.start(urlString: url)
        urlText = ""
    }
}

// ── Document picker ───────────────────────────────────────────────────────────
struct DocumentPicker: UIViewControllerRepresentable {
    let album:          String
    let supportedTypes: [UTType]

    func makeCoordinator() -> Coordinator { Coordinator(album: album) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let album: String
        init(album: String) { self.album = album }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            DownloadManager.shared.importLocalFiles(urls, album: album.isEmpty ? "Local" : album)
        }
    }
}

// ── Download row ──────────────────────────────────────────────────────────────
struct DLRow: View {
    let item: DLItem
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: "1e1e24"))
                    .frame(width: 32, height: 32)
                Image(systemName: iconName).font(.system(size: 13))
                    .foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13))
                    .foregroundColor(Color(hex: "ede8df")).lineLimit(1)
                Text(item.message).font(.custom("Courier New", size: 10))
                    .foregroundColor(msgColor)
            }
            Spacer()
        }.padding(.horizontal, 18).padding(.vertical, 11)
    }
    var iconName: String {
        switch item.status {
        case .pending:     return "clock"
        case .downloading: return "arrow.down.circle"
        case .done:        return "checkmark"
        case .error:       return "xmark"
        }
    }
    var iconColor: Color {
        switch item.status {
        case .pending:     return Color(hex: "6b6760")
        case .downloading: return Color(hex: "c8a96e")
        case .done:        return Color(hex: "5cac78")
        case .error:       return Color(hex: "c45c5c")
        }
    }
    var msgColor: Color {
        item.status == .error ? Color(hex: "c45c5c") : Color(hex: "6b6760")
    }
}