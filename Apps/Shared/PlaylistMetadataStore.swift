import Core
import Foundation

/// Icke-hemlig metadata om en spellista. Sparas i UserDefaults så att spellistorna överlever att tvOS rensar
/// cache-databasen. Server, URL och inloggning ligger aldrig här, bara i `CredentialStore`.
///
/// Synkfält (äldre sparade värden saknar dem och avkodas till standardvärden):
/// - `updatedAt`: ändringstid för last-writer-wins (`distantPast` för gamla poster).
/// - `deletedAt`: gravsten. En borttagen spellista ligger kvar som gravsten tills den prunats.
/// - `fromRemote`: spellistan kom från en annan enhet och har ingen lokal inloggning ännu.
/// - `remoteDeletionPending`: gravstenen kom från en annan enhet och lokal städning (katalog, nyckelring) återstår.
struct PlaylistMetadata: Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var kind: PlaylistSourceKind
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var fromRemote: Bool
    var remoteDeletionPending: Bool

    init(_ p: Playlist, updatedAt: Date = Date()) {
        id = p.id
        name = p.name
        kind = p.kind
        createdAt = p.createdAt
        self.updatedAt = updatedAt
        deletedAt = nil
        fromRemote = false
        remoteDeletionPending = false
    }

    init(id: UUID, name: String, kind: PlaylistSourceKind, createdAt: Date, updatedAt: Date,
         deletedAt: Date? = nil, fromRemote: Bool = false, remoteDeletionPending: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.fromRemote = fromRemote
        self.remoteDeletionPending = remoteDeletionPending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(PlaylistSourceKind.self, forKey: .kind)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        fromRemote = try c.decodeIfPresent(Bool.self, forKey: .fromRemote) ?? false
        remoteDeletionPending = try c.decodeIfPresent(Bool.self, forKey: .remoteDeletionPending) ?? false
    }

    var isDeleted: Bool { deletedAt != nil }
    /// Spellistan finns bara som metadata från en annan enhet: inloggning saknas lokalt tills användaren anger den.
    var isRemoteOnly: Bool { fromRemote && !isDeleted }

    var playlist: Playlist { Playlist(id: id, name: name, kind: kind, createdAt: createdAt) }
}

@MainActor
final class PlaylistMetadataStore {
    static let key = "playlists.v1"
    /// Gravstenar äldre än så här tas bort vid nästa skrivning.
    static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// Levande spellistor. Gravstenar syns aldrig här, så befintliga anropare beter sig som förut.
    func all() -> [PlaylistMetadata] {
        allIncludingTombstones().filter { !$0.isDeleted }
    }

    /// Levande poster och gravstenar (för synk).
    func allIncludingTombstones() -> [PlaylistMetadata] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([PlaylistMetadata].self, from: data)
        else { return [] }
        return entries
    }

    /// Sparar (eller ersätter) spellistan lokalt. Rensar `fromRemote`: användaren har lagt in inloggningen.
    func save(_ playlist: Playlist) {
        var entries = allIncludingTombstones().filter { $0.id != playlist.id }
        entries.append(PlaylistMetadata(playlist, updatedAt: now()))
        write(entries)
    }

    /// Tar bort levande spellistor och lämnar en gravsten kvar (för synk). Okända id:n och redan raderade
    /// poster lämnas orörda.
    func remove(_ ids: some Sequence<UUID>) {
        let drop = Set(ids)
        guard !drop.isEmpty else { return }
        let stamp = now()
        var entries = allIncludingTombstones()
        for i in entries.indices where drop.contains(entries[i].id) && !entries[i].isDeleted {
            entries[i].deletedAt = stamp
            entries[i].updatedAt = stamp
            entries[i].fromRemote = false
            entries[i].remoteDeletionPending = false
        }
        write(entries)
    }

    /// Lokal städning: hårdraderar poster utan att lämna gravsten (synkas alltså inte som radering). Bara
    /// användarens uttryckliga borttagning ska använda `remove`.
    func discard(_ ids: some Sequence<UUID>) {
        let drop = Set(ids)
        guard !drop.isEmpty else { return }
        write(allIncludingTombstones().filter { !drop.contains($0.id) })
    }

    // MARK: Synk

    /// Tar emot en levande spellista från en annan enhet (last-writer-wins på `updatedAt`). Okänd spellista läggs
    /// till som `fromRemote`. En lokal gravsten ersätts bara av en nyare levande post. Returnerar `true` om något ändrades.
    @discardableResult
    func applyRemote(id: UUID, name: String, kind: PlaylistSourceKind, createdAt: Date, updatedAt: Date) -> Bool {
        var entries = allIncludingTombstones()
        if let i = entries.firstIndex(where: { $0.id == id }) {
            guard updatedAt > entries[i].updatedAt else { return false }
            let wasDeleted = entries[i].isDeleted
            entries[i].name = name
            entries[i].kind = kind
            entries[i].createdAt = createdAt
            entries[i].updatedAt = updatedAt
            entries[i].deletedAt = nil
            entries[i].remoteDeletionPending = false
            // Återuppstod efter lokal radering: inloggningen är borta, så den räknas som fjärrspellista.
            if wasDeleted { entries[i].fromRemote = true }
        } else {
            entries.append(PlaylistMetadata(id: id, name: name, kind: kind, createdAt: createdAt,
                                            updatedAt: updatedAt, fromRemote: true))
        }
        write(entries)
        return true
    }

    /// Tar emot en gravsten från en annan enhet. Markerar en levande lokal post som borttagen bara om gravstenen är
    /// minst lika ny som den lokala posten, och flaggar den för lokal städning (`pendingRemoteDeletions`). Själva
    /// städningen av katalog och nyckelring görs av anroparen. Okända id:n ignoreras (synkens egen gravstensmängd
    /// håller dem). Returnerar `true` om en lokal post markerades.
    @discardableResult
    func applyRemoteTombstone(id: UUID, deletedAt: Date) -> Bool {
        var entries = allIncludingTombstones()
        guard let i = entries.firstIndex(where: { $0.id == id }), !entries[i].isDeleted,
              deletedAt >= entries[i].updatedAt
        else { return false }
        entries[i].deletedAt = deletedAt
        entries[i].updatedAt = deletedAt
        entries[i].fromRemote = false
        entries[i].remoteDeletionPending = true
        write(entries)
        return true
    }

    /// Spellistor som raderats av en annan enhet och vars lokala städning (katalog, nyckelring) ännu inte kvitterats.
    func pendingRemoteDeletions() -> [UUID] {
        allIncludingTombstones().filter { $0.isDeleted && $0.remoteDeletionPending }.map(\.id)
    }

    /// Kvitterar att den lokala städningen av fjärrraderade spellistor är klar.
    func markRemoteDeletionHandled(_ ids: some Sequence<UUID>) {
        let handled = Set(ids)
        guard !handled.isEmpty else { return }
        var entries = allIncludingTombstones()
        for i in entries.indices where handled.contains(entries[i].id) { entries[i].remoteDeletionPending = false }
        write(entries)
    }

    /// Tar bort gravstenar äldre än 90 dagar. Sker även vid varje skrivning.
    func pruneTombstones() {
        write(allIncludingTombstones())
    }

    private func write(_ entries: [PlaylistMetadata]) {
        let cutoff = now().addingTimeInterval(-Self.tombstoneRetention)
        let kept = entries.filter { entry in
            guard let deletedAt = entry.deletedAt else { return true }
            // Ej kvitterad fjärrradering behålls tills städningen är klar.
            return entry.remoteDeletionPending || deletedAt >= cutoff
        }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
