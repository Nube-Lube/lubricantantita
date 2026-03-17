import SwiftUI

struct YouTubeView: View {
    @ObservedObject var dl = DownloadManager.shared
    @State private var urlText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("YouTube")
                    .font(.custom("Georgia", size: 26))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Input
            HStack(spacing: 8) {
                TextField("Paste a YouTube video or playlist URL…", text: $urlText)
                    .font(.custom("Courier New", size: 12))
                    .foregroundColor(Color(hex: "ede8df"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .focused($focused)
                    .padding(10)
                    .background(Color(hex: "1e1e24"))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focused ? Color(hex: "c8a96e") : Color.white.opacity(0.07))
                    )

                Button {
                    focused = false
                    startDownload()
                } label: {
                    Text(dl.isDownloading ? "…" : "Download")
                        .font(.custom("Courier New", size: 12))
                        .fontWeight(.medium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(dl.isDownloading ? Color(hex: "1e1e24") : Color(hex: "c8a96e"))
                        .foregroundColor(dl.isDownloading ? Color(hex: "6b6760") : Color(hex: "080809"))
                        .cornerRadius(10)
                }
                .disabled(dl.isDownloading)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            // Notice
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("Needs internet to download. Saved songs play offline.")
                    .font(.custom("Courier New", size: 11))
                Spacer()
            }
            .foregroundColor(Color(hex: "6b6760"))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            // Download list
            if dl.items.isEmpty {
                EmptyStateView(title: "No downloads yet",
                               subtitle: "Paste a YouTube URL above to get started")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dl.items) { item in
                            DLRow(item: item)
                            Divider()
                                .background(Color.white.opacity(0.04))
                                .padding(.leading, 18)
                        }
                    }
                    .padding(.vertical, 8)
                }
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

struct DLRow: View {
    let item: DLItem

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "1e1e24"))
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "ede8df"))
                    .lineLimit(1)
                Text(item.message)
                    .font(.custom("Courier New", size: 10))
                    .foregroundColor(msgColor)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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
        switch item.status {
        case .error:       return Color(hex: "c45c5c")
        default:           return Color(hex: "6b6760")
        }
    }
}
