import Foundation
import Combine

class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    @Published var tracks: [Track] = []

    private let metaKey = "wireless.tracks.v1"
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { load() }

    var albums: [String: [Track]] {
        var d = [String: [Track]]()
        for t in tracks { d[t.album, default: []].append(t) }
        for k in d.keys { d[k]?.sort { $0.addedAt < $1.addedAt } }
        return d
    }

    func audioURL(for track: Track) -> URL {
        docs.appendingPathComponent(track.filename)
    }

    func reload() {
        load()
        objectWillChange.send()
    }

    func add(_ track: Track) {
        tracks.append(track)
        save()
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: audioURL(for: track))
        tracks.removeAll { $0.id == track.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: metaKey),
              let decoded = try? JSONDecoder().decode([Track].self, from: data)
        else { return }
        tracks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: metaKey)
    }
}
