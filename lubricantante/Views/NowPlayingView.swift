import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var audio = AudioManager.shared

    var body: some View {
        ZStack {
            // Background glow
            RadialGradient(
                gradient: Gradient(colors: [Color(hex: "c8a96e").opacity(0.12), Color.clear]),
                center: .top, startRadius: 0, endRadius: 400
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Vinyl disc
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(colors: [
                                Color(hex: "1a1a1e"), Color(hex: "111114"),
                                Color(hex: "1a1a1e"), Color(hex: "0e0e11"),
                                Color(hex: "1a1a1e")
                            ], center: .center)
                        )
                        .frame(width: discSize, height: discSize)
                        .shadow(color: .black.opacity(0.7), radius: 24, y: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                        )

                    // Grooves
                    ForEach([0.72, 0.82, 0.92], id: \.self) { r in
                        Circle()
                            .stroke(Color.white.opacity(0.03), lineWidth: 0.5)
                            .frame(width: discSize * r, height: discSize * r)
                    }

                    // Label
                    Circle()
                        .fill(Color(hex: "1e1e24"))
                        .frame(width: discSize * 0.32, height: discSize * 0.32)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: discSize * 0.09))
                                .foregroundColor(Color(hex: "6b6760"))
                        )
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                }
                .rotationEffect(audio.isPlaying
                    ? .degrees(audio.currentTime * 6)
                    : .degrees(0))
                .animation(audio.isPlaying
                    ? .linear(duration: 0.25)
                    : .default, value: audio.currentTime)
                .padding(.bottom, 32)

                Spacer()

                // Track info
                VStack(spacing: 5) {
                    Text(audio.currentTrack?.name ?? "Nothing playing")
                        .font(.custom("Georgia", size: 20))
                        .fontWeight(.semibold)
                        .foregroundColor(Color(hex: "ede8df"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)

                    Text(audio.currentTrack?.album ?? "Download songs from the YouTube tab")
                        .font(.custom("Courier New", size: 11))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundColor(Color(hex: "6b6760"))
                        .lineLimit(1)
                }
                .padding(.bottom, 20)

                // Progress
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { audio.duration > 0 ? audio.currentTime / audio.duration : 0 },
                            set: { audio.seek(to: $0 * audio.duration) }
                        )
                    )
                    .tint(Color(hex: "c8a96e"))

                    HStack {
                        Text(formatTime(audio.currentTime))
                        Spacer()
                        Text(formatTime(audio.duration))
                    }
                    .font(.custom("Courier New", size: 10))
                    .foregroundColor(Color(hex: "6b6760"))
                }
                .padding(.bottom, 16)

                // Controls
                HStack(spacing: 28) {
                    CtrlBtn(icon: "shuffle", active: audio.shuffle) {
                        audio.shuffle.toggle()
                    }
                    CtrlBtn(icon: "backward.end.fill") { audio.previous() }

                    // Play/Pause
                    Button { audio.toggle() } label: {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color(hex: "080809"))
                            .frame(width: 60, height: 60)
                            .background(Color(hex: "c8a96e"))
                            .clipShape(Circle())
                            .shadow(color: Color(hex: "c8a96e").opacity(0.35), radius: 16)
                    }

                    CtrlBtn(icon: "forward.end.fill") { audio.next() }
                    CtrlBtn(icon: "repeat", active: audio.repeatOne) {
                        audio.repeatOne.toggle()
                    }
                }
                .padding(.bottom, 18)

                // Volume
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "6b6760"))
                    Slider(value: Binding(
                        get: { Double(audio.volume) },
                        set: { audio.setVolume(Float($0)) }
                    ))
                    .tint(Color(hex: "c8a96e"))
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "6b6760"))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
    }

    var discSize: CGFloat {
        min(UIScreen.main.bounds.width * 0.62, 240)
    }

    func formatTime(_ t: Double) -> String {
        guard t.isFinite && t > 0 else { return "0:00" }
        let m = Int(t) / 60, s = Int(t) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

struct CtrlBtn: View {
    let icon: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(active ? Color(hex: "c8a96e") : Color(hex: "6b6760"))
                .frame(width: 40, height: 40)
        }
    }
}
