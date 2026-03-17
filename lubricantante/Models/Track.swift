import Foundation

struct Track: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var album: String
    var filename: String
    var addedAt: Date

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
