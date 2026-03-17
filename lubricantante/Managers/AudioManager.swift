import Foundation
import AVFoundation
import Combine
import MediaPlayer

class AudioManager: ObservableObject {
    static let shared = AudioManager()

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var volume: Float = 1.0
    @Published var shuffle = false
    @Published var repeatOne = false

    var queue: [Track] = []
    var history: [Track] = []

    private var player: AVPlayer?
    private var timeObserver: Any?

    init() {
        setupSession()
        setupRemoteCommands()
    }

    // ── Session ───────────────────────────────────────────────
    private func setupSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    // ── Lock screen / Control Centre ──────────────────────────
    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget  { [weak self] _ in self?.play();     return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause();    return .success }
        c.nextTrackCommand.addTarget     { [weak self] _ in self?.next();     return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let t = currentTrack else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:            t.name,
            MPMediaItemPropertyAlbumTitle:       t.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: max(duration, 1),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    // ── Playback ──────────────────────────────────────────────
    func playTrack(_ track: Track) {
        currentTrack = track
        currentTime  = 0
        duration     = 1

        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        NotificationCenter.default.removeObserver(
            self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        let url = LibraryManager.shared.audioURL(for: track)
        player = AVPlayer(url: url)
        player?.volume = volume

        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let d = self.player?.currentItem?.duration.seconds, d.isFinite {
                self.duration = d
            }
            self.updateNowPlayingInfo()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(itemEnded),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem)

        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    @objc private func itemEnded() {
        if repeatOne { seek(to: 0); play(); return }
        next()
    }

    func play()   { player?.play();  isPlaying = true  }
    func pause()  { player?.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to t: Double) {
        player?.seek(to: CMTime(seconds: t,
                                preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }

    func setVolume(_ v: Float) { volume = v; player?.volume = v }

    // ── Queue ──────────────────────────────────────────────────
    func next() {
        guard !queue.isEmpty else { pause(); return }
        var track: Track
        if shuffle {
            let i = Int.random(in: 0..<queue.count)
            track = queue.remove(at: i)
        } else {
            track = queue.removeFirst()
        }
        if let c = currentTrack { history.append(c) }
        playTrack(track)
    }

    func previous() {
        if !history.isEmpty {
            if let c = currentTrack { queue.insert(c, at: 0) }
            playTrack(history.removeLast())
        } else {
            seek(to: 0)
        }
    }

    func queueAll(_ tracks: [Track], playNow: Bool = false) {
        if playNow {
            queue = Array(tracks.dropFirst())
            if let first = tracks.first { playTrack(first) }
        } else {
            queue.append(contentsOf: tracks)
        }
    }

    func shuffleAll(_ tracks: [Track]) {
        let all = tracks.shuffled()
        if let first = all.first {
            queue = Array(all.dropFirst())
            playTrack(first)
        }
    }
}
