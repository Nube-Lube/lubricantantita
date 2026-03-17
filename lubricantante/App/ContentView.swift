import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NowPlayingView()
                .tabItem {
                    Label("Now", systemImage: "circle.fill")
                }
                .tag(0)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(1)

            QueueView()
                .tabItem {
                    Label("Queue", systemImage: "list.number")
                }
                .tag(2)

            YouTubeView()
                .tabItem {
                    Label("YouTube", systemImage: "play.rectangle.fill")
                }
                .tag(3)
        }
        .tint(Color(hex: "c8a96e"))
        .background(Color(hex: "080809"))
        .preferredColorScheme(.dark)
    }
}

// ── Color hex helper ──────────────────────────────────────────────
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
