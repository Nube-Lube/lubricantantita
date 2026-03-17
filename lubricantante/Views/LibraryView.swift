import SwiftUI

struct LibraryView: View {
    @ObservedObject var library = LibraryManager.shared
    @ObservedObject var audio   = AudioManager.shared
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Library")
                    .font(.custom("Georgia", size: 26))
                Spacer()
                Button {
                    let all = library.tracks
                    audio.shuffleAll(all)
                } label: {
                    Text("Shuffle All")
                        .font(.custom("Courier New", size: 11))
                        .tracking(0.8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(hex: "1e1e24"))
                        .foregroundColor(Color(hex: "ede8df"))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.07)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.06)), alignment: .bottom)

            if library.tracks.isEmpty {
                EmptyStateView(title: "Library is empty",
                               subtitle: "Download songs from the YouTube tab")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.albums.keys.sorted(), id: \.self) { album in
                            AlbumSection(
                                album: album,
                                tracks: library.albums[album] ?? [],
                                isExpanded: expanded.contains(album),
                                onToggle: {
                                    if expanded.contains(album) { expanded.remove(album) }
                                    else { expanded.insert(album) }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

struct AlbumSection: View {
    let album: String
    let tracks: [Track]
    let isExpanded: Bool
    let onToggle: () -> Void

    @ObservedObject var audio = AudioManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Album row
            Button(action: onToggle) {
                HStack {
                    Text(album)
                        .font(.custom("Georgia", size: 16))
                        .foregroundColor(Color(hex: "ede8df"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                        .font(.custom("Courier New", size: 10))
                        .tracking(0.8)
                        .foregroundColor(Color(hex: "6b6760"))

                    // Queue album button
                    Button {
                        audio.queue.append(contentsOf: tracks)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "6b6760"))
                    }
                    .padding(.leading, 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "6b6760"))
                        .padding(.leading, 4)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)

            // Tracks
            if isExpanded {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track, index: i + 1)
                }
            }

            Divider()
                .background(Color.white.opacity(0.05))
        }
    }
}

struct TrackRow: View {
    let track: Track
    let index: Int

    @ObservedObject var audio   = AudioManager.shared
    @ObservedObject var library = LibraryManager.shared

    var isPlaying: Bool { audio.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.custom("Courier New", size: 11))
                .foregroundColor(isPlaying ? Color(hex: "c8a96e") : Color(hex: "6b6760"))
                .frame(width: 22, alignment: .trailing)

            Text(track.name)
                .font(.system(size: 13))
                .foregroundColor(isPlaying ? Color(hex: "c8a96e") : Color(hex: "ede8df"))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Add to queue
            Button {
                audio.queue.append(track)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "6b6760"))
            }

            // Delete
            Button {
                library.delete(track)
                if audio.currentTrack?.id == track.id {
                    audio.next()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "6b6760"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color(hex: isPlaying ? "1a1a1e" : "080809"))
        .contentShape(Rectangle())
        .onTapGesture {
            audio.queue.insert(track, at: 0)
            audio.next()
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title)
                .font(.custom("Georgia", size: 20))
                .foregroundColor(Color(hex: "ede8df"))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "6b6760"))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
