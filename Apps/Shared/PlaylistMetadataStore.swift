import Core
import Foundation

/// Icke-hemlig metadata om en spellista. Sparas i UserDefaults så att spellistorna överlever att tvOS rensar
/// cache-databasen. Server, URL och inloggning ligger aldrig här, bara i `CredentialStore`.
struct PlaylistMetadata: Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var kind: PlaylistSourceKind
    var createdAt: Date

    init(_ p: Playlist) {
        id = p.id
        name = p.name
        kind = p.kind
        createdAt = p.createdAt
    }

    var playlist: Playlist { Playlist(id: id, name: name, kind: kind, createdAt: createdAt) }
}

@MainActor
final class PlaylistMetadataStore {
    static let key = "playlists.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [PlaylistMetadata] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([PlaylistMetadata].self, from: data)
        else { return [] }
        return entries
    }

    func save(_ playlist: Playlist) {
        var entries = all().filter { $0.id != playlist.id }
        entries.append(PlaylistMetadata(playlist))
        write(entries)
    }

    func remove(_ ids: some Sequence<UUID>) {
        let drop = Set(ids)
        guard !drop.isEmpty else { return }
        write(all().filter { !drop.contains($0.id) })
    }

    private func write(_ entries: [PlaylistMetadata]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
