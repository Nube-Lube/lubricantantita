import SwiftUI
import UniformTypeIdentifiers

struct YouTubeView: View {
    @ObservedObject var dl   = DownloadManager.shared
    @ObservedObject var auth = AuthManager.shared
    @State private var urlText      = ""
    @State private var showLogin    = false
    @State private var showFilePicker = false
    @State private var albumName    = "Local"
    @FocusState private var focused: Bool

    // Supported audio/video types for import
    private let supportedTypes: [UTType] = [
        .audio, .mp3, UTType("public.m4a-audio")!, .wav,
        UTType("org.xiph.flac") ?? .audio,
        UTType("public.ogg-vorbis-audio") ?? .audio,
        .mpeg4Movie, .movie, .video
    ].compactMap { $0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("YouTube")
                    .font(.custom("Georgia", size: 26))
                Spacer()
                Button {
                    if auth.isSignedIn { auth.signOut() }
                    else { showLogin = true }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(auth.isSignedIn ? Color(hex:"5cac78") : Color(hex:"c45c5c"))
                            .frame(width: 8, height: 8)
                        Text(auth.isSignedIn ? "Signed in" : "Sign in")
                            .font(.custom("Courier New", size: 11))
                            .foregroundColor(auth.isSignedIn ? Color(hex:"5cac78") : Color(hex:"c8a96e"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(hex:"1e1e24")).cornerRadius(99)
                    .overlay(RoundedRectangle(cornerRadius:99).stroke(Color.white.opacity(0.07)))
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            // Sign-in notice
            if !auth.isSignedIn {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(Color(hex:"c8a96e"))
                    Text("Sign in to Google account for reliable downloads")
                        .font(.custom("Courier New", size: 11)).foregroundColor(Color(hex:"6b6760"))
                    Spacer()
                }.padding(.horizontal, 18).padding(.bottom, 8)
            }

            // YouTube URL input
            HStack(spacing: 8) {
                TextField("Paste YouTube video or playlist URL…", text: $urlText)
                    .font(.custom("Courier New", size: 12))
                    .foregroundColor(Color(hex:"ede8df"))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .keyboardType(.URL).focused($focused)
                    .padding(10).background(Color(hex:"1e1e24")).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius:10)
                        .stroke(focused ? Color(hex:"c8a96e") : Color.white.opacity(0.07)))

                Button {
                    focused = false
                    if !auth.isSignedIn { showLogin = true }
                    else { startDownload() }
                } label: {
                    Text(dl.isDownloading ? "…" : (auth.isSignedIn ? "Download" : "Sign in"))
                        .font(.custom("Courier New", size: 12)).fontWeight(.medium)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(dl.isDownloading ? Color(hex:"1e1e24") : Color(hex:"c8a96e"))
                        .foregroundColor(dl.isDownloading ? Color(hex:"6b6760") : Color(hex:"080809"))
                        .cornerRadius(10)
                }.disabled(dl.isDownloading)
            }
            .padding(.horizontal, 18).padding(.bottom, 8)

            // Local import row
            HStack(spacing: 8) {
                TextField("Album name", text: $albumName)
                    .font(.custom("Courier New", size: 12))
                    .foregroundColor(Color(hex:"ede8df"))
                    .padding(8).background(Color(hex:"1e1e24")).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius:8)
                        .stroke(Color.white.opacity(0.07)))
                    .frame(maxWidth: 130)

                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                        Text("Import Files")
                            .font(.custom("Courier New", size: 12)).fontWeight(.medium)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(hex:"1e1e24")).foregroundColor(Color(hex:"ede8df"))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius:10)
                        .stroke(Color.white.opacity(0.07)))
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            // Download list
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
        .sheet(isPresented: $showLogin)    { YouTubeLoginView() }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(album: albumName, supportedTypes: [
                .audio, .mp3, .wav, .mpeg4Movie, .movie
            ])
        }
    }

    private func startDownload() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http") else { return }
        dl.start(urlString: url)
        urlText = ""
    }
}

// ── Document picker wrapper ───────────────────────────────────────────────────
struct DocumentPicker: UIViewControllerRepresentable {
    let album:          String
    let supportedTypes: [UTType]

    func makeCoordinator() -> Coordinator { Coordinator(album: album) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes,
                                                    asCopy: true)
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
                RoundedRectangle(cornerRadius: 8).fill(Color(hex:"1e1e24"))
                    .frame(width: 32, height: 32)
                Image(systemName: iconName).font(.system(size: 13))
                    .foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13))
                    .foregroundColor(Color(hex:"ede8df")).lineLimit(1)
                Text(item.message).font(.custom("Courier New", size: 10))
                    .foregroundColor(msgColor)
            }
            Spacer()
        }.padding(.horizontal, 18).padding(.vertical, 11)
    }
    var iconName: String {
        switch item.status {
        case .pending: return "clock"; case .downloading: return "arrow.down.circle"
        case .done: return "checkmark"; case .error: return "xmark"
        }
    }
    var iconColor: Color {
        switch item.status {
        case .pending: return Color(hex:"6b6760"); case .downloading: return Color(hex:"c8a96e")
        case .done:    return Color(hex:"5cac78");  case .error:      return Color(hex:"c45c5c")
        }
    }
    var msgColor: Color {
        item.status == .error ? Color(hex:"c45c5c") : Color(hex:"6b6760")
    }
}
