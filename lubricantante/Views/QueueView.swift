import SwiftUI

struct QueueView: View {
    @ObservedObject var audio = AudioManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.custom("Georgia", size: 26))
                Spacer()
                if !audio.queue.isEmpty {
                    Button {
                        // Assign a fresh empty array rather than mutating in-place
                        // — avoids a crash where ForEach re-evaluates stale indices
                        audio.queue = []
                    } label: {
                        Text("Clear")
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
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .overlay(Rectangle().frame(height: 1)
                .foregroundColor(Color.white.opacity(0.06)), alignment: .bottom)

            if audio.queue.isEmpty {
                EmptyStateView(title: "Queue is empty",
                               subtitle: "Tap a track name to play it\nor + to add it to the queue")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Use the track's stable UUID as the ForEach id, NOT the
                        // enumerated index — so removals don't crash on stale indices
                        ForEach(audio.queue) { track in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.name)
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(hex: "ede8df"))
                                        .lineLimit(1)
                                    Text(track.album)
                                        .font(.custom("Courier New", size: 10))
                                        .foregroundColor(Color(hex: "6b6760"))
                                }
                                Spacer()
                                Button {
                                    // Remove by identity, not index
                                    audio.queue.removeAll { $0.id == track.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14))
                                        .foregroundColor(Color(hex: "6b6760"))
                                        .padding(8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)

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
}