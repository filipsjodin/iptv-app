import Foundation
import Core
import Personal
import PlaybackCore
import Sync

/// Spellistmetadata som synkas. Aldrig server, användarnamn, lösenord eller URL:er (de ligger i `PlaylistSecret`).
public struct PlaylistMeta: Equatable, Sendable {
    public var name: String
    public var kind: PlaylistSourceKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, kind: PlaylistSourceKind, createdAt: Date, updatedAt: Date) {
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SubtitleOffsetKey: Hashable, Sendable {
    public var profileID: UUID
    public var playlistID: UUID
    public var kind: ContentKind
    public var providerID: String

    public init(profileID: UUID, playlistID: UUID, kind: ContentKind, providerID: String) {
        self.profileID = profileID
        self.playlistID = playlistID
        self.kind = kind
        self.providerID = providerID
    }
}

public struct SubtitleOffset: Equatable, Sendable {
    public var offsetMs: Int
    public var updatedAt: Date

    public init(offsetMs: Int, updatedAt: Date) {
        self.offsetMs = offsetMs
        self.updatedAt = updatedAt
    }
}

/// Kapaciteter som gäller identiskt på alla enheter (så att utträngning konvergerar).
public struct SyncCapacities: Equatable, Sendable {
    public var progress: Int
    public var watchlist: Int
    public var ratings: Int

    public init(progress: Int = 500, watchlist: Int = 1000, ratings: Int = 2000) {
        self.progress = progress
        self.watchlist = watchlist
        self.ratings = ratings
    }
}

/// Allt som synkas för en enhet, som ett rent värde. Task 5:s koordinator laddar det från de riktiga
/// lagren, muterar det (lokala ändringar) och skriver tillbaka ändringar efter `SyncMapper.apply`.
///
/// Jämlikhet (`==`) jämför det som är synligt för synken (kanoniska poster), inte bokföring
/// (`origins`, `childTombstones`) eller enhetslokala fält (`recentChannels`).
public struct SyncableState: Sendable, Equatable {
    public var deviceID: String
    public var capacities: SyncCapacities
    public var profiles: [UUID: Profile] = [:]
    /// Profilgravstenar (tidpunkt). En raderad profil kan aldrig återuppstå och dess barnposter släpps.
    public var deletedProfiles: [UUID: Date] = [:]
    public var playlists: [UUID: PlaylistMeta] = [:]
    public var deletedPlaylists: [UUID: Date] = [:]
    public var personal: [UUID: PersonalSnapshot] = [:]
    public var progress: [UUID: [ProgressKey: WatchProgress]] = [:]
    public var settings: [UUID: PlaybackSettings] = [:]
    public var subtitleOffsets: [SubtitleOffsetKey: SubtitleOffset] = [:]

    /// Gravstenar för poster som inte längre finns i tillståndet (barn till en profil som raderats här,
    /// kapacitetsutträngda framsteg). Bokföring: tas med i `records`, men inte i jämlikheten.
    var childTombstones: [SyncRecordID: Date] = [:]
    /// Ursprung för poster som kommer från andra enheter (gäller bara om `updatedAt` stämmer).
    var origins: [SyncRecordID: OriginStamp] = [:]

    struct OriginStamp: Equatable, Sendable {
        var origin: String
        var updatedAt: Date
    }

    /// Bokföring som måste överleva en omstart (annars kan en raderad profil återuppstå): gravstenar för profiler,
    /// spellistor och barnposter samt ursprung. Codable; läses och sätts av appens lagringslager.
    public var bookkeeping: SyncBookkeeping {
        get {
            SyncBookkeeping(
                deletedProfiles: deletedProfiles.map { SyncBookkeeping.Stamp(id: $0.key.uuidString, at: $0.value) }
                    .sorted { $0.id < $1.id },
                deletedPlaylists: deletedPlaylists.map { SyncBookkeeping.Stamp(id: $0.key.uuidString, at: $0.value) }
                    .sorted { $0.id < $1.id },
                childTombstones: childTombstones.map { SyncBookkeeping.RecordStamp(id: $0.key, at: $0.value) }
                    .sorted { ($0.id.kind.rawValue, $0.id.key) < ($1.id.kind.rawValue, $1.id.key) },
                origins: origins.map { SyncBookkeeping.Origin(id: $0.key, origin: $0.value.origin, at: $0.value.updatedAt) }
                    .sorted { ($0.id.kind.rawValue, $0.id.key) < ($1.id.kind.rawValue, $1.id.key) })
        }
        set {
            deletedProfiles = Dictionary(newValue.deletedProfiles.compactMap { e in
                UUID(uuidString: e.id).map { ($0, e.at) } }, uniquingKeysWith: max)
            deletedPlaylists = Dictionary(newValue.deletedPlaylists.compactMap { e in
                UUID(uuidString: e.id).map { ($0, e.at) } }, uniquingKeysWith: max)
            childTombstones = Dictionary(newValue.childTombstones.map { ($0.id, $0.at) }, uniquingKeysWith: max)
            origins = Dictionary(newValue.origins.map { ($0.id, OriginStamp(origin: $0.origin, updatedAt: $0.at)) },
                                 uniquingKeysWith: { $1 })
        }
    }

    public init(deviceID: String, capacities: SyncCapacities = SyncCapacities()) {
        self.deviceID = deviceID
        self.capacities = capacities
    }

    // MARK: Lokala mutationer som kräver bokföring

    /// Raderar en profil lokalt: gravsten på profilen och alla dess barnposter, all profildata tas bort.
    public mutating func deleteProfile(_ id: UUID, now: Date) {
        let childIDs = SyncMapper.childRecordIDs(of: id, in: self)
        removeProfileData(id)
        deletedProfiles[id] = now
        for c in childIDs { childTombstones[c] = now }
        pruneChildTombstones(now: now)
    }

    /// Barngravstenar behöver bara överleva tills molnet sett dem; `deletedProfiles` hindrar uppståndelse ändå
    /// (barnposter till en raderad profil släpps). Äldre än `childTombstoneRetention` rensas.
    public static let childTombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    public mutating func pruneChildTombstones(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.childTombstoneRetention)
        childTombstones = childTombstones.filter { $0.value >= cutoff }
    }

    /// Raderar en spellista lokalt, med dess profiler (gravsten på varje).
    public mutating func deletePlaylist(_ id: UUID, now: Date) {
        for p in profiles.values where p.playlistID == id { deleteProfile(p.id, now: now) }
        playlists[id] = nil
        deletedPlaylists[id] = now
    }

    mutating func removeProfileData(_ id: UUID) {
        profiles[id] = nil
        personal[id] = nil
        progress[id] = nil
        settings[id] = nil
        for k in subtitleOffsets.keys where k.profileID == id { subtitleOffsets[k] = nil }
    }

    // MARK: Läs-hjälpare

    public func liveWatchlist(_ profile: UUID) -> [ItemRef] { personal[profile]?.liveWatchlist ?? [] }
    public func liveFavorites(_ profile: UUID) -> [String] { personal[profile]?.liveFavorites ?? [] }
    public func ratings(_ profile: UUID) -> [ItemRef: Rating] {
        Dictionary((personal[profile]?.ratingEntries ?? []).compactMap { e in e.rating.map { (e.item, $0) } },
                   uniquingKeysWith: { $1 })
    }

    public static func == (a: SyncableState, b: SyncableState) -> Bool {
        SyncMapper.canonical(a) == SyncMapper.canonical(b)
    }
}

/// Vad en `apply` ändrade (för UI-uppdatering) plus poster koordinatorn måste pusha.
public struct SyncChangeSet: Equatable, Sendable {
    public var profiles: Set<UUID> = []
    public var removedProfiles: Set<UUID> = []
    public var playlists: Set<UUID> = []
    public var removedPlaylists: Set<UUID> = []
    public var progress: Set<UUID> = []
    public var personal: Set<UUID> = []
    public var settings: Set<UUID> = []
    public var subtitleOffsets: Set<UUID> = []
    /// Poster som släpptes eftersom deras profil är raderad.
    public var droppedOrphans: Int = 0
    /// Poster som enheten själv måste pusha efter apply: återbekräftade gravstenar (en live profil/spellista
    /// dök upp efter radering) och kapacitetsutträngningar. Allt annat är exakt det som redan finns i molnet.
    public var dirty: Set<SyncRecordID> = []

    public init() {}

    public var isEmpty: Bool {
        profiles.isEmpty && removedProfiles.isEmpty && playlists.isEmpty && removedPlaylists.isEmpty
            && progress.isEmpty && personal.isEmpty && settings.isEmpty && subtitleOffsets.isEmpty
    }
}

/// Poster som ännu inte pushats. Behålls vid fel och rensas först när pushen lyckats.
public struct SyncDirtySet: Equatable, Sendable {
    public private(set) var ids: Set<SyncRecordID> = []

    public init(_ ids: Set<SyncRecordID> = []) { self.ids = ids }

    public var isEmpty: Bool { ids.isEmpty }
    public mutating func mark(_ more: some Sequence<SyncRecordID>) { ids.formUnion(more) }
    public mutating func markAll(in state: SyncableState) {
        ids.formUnion(SyncMapper.records(from: state).map(\.id))
    }
    /// Markerar poster som skiljer sig mellan två tillstånd (efter en lokal ändring).
    public mutating func markChanges(from old: SyncableState, to new: SyncableState) {
        ids.formUnion(SyncMapper.changedIDs(from: old, to: new))
    }

    /// Pushar de smutsiga posterna. Vid fel står dirty-mängden kvar orörd. Poster som markerades under
    /// väntan (kan inte hända med värdesemantik, men ids matchas exakt) rensas inte i onödan.
    public mutating func push(from state: SyncableState, via transport: some SyncTransport) async throws {
        let batch = SyncMapper.records(from: state, dirty: ids)
        if !batch.isEmpty { try await transport.push(batch) }
        // Lyckad push: rensa pushade ids och ids utan någon post (inget att pusha).
        ids.subtract(batch.map(\.id))
        ids.subtract(ids.subtracting(SyncMapper.recordIDs(in: state)))
    }
}

/// Persistensformat för det som `SyncableState` håller utöver själva data (se `SyncableState.bookkeeping`).
public struct SyncBookkeeping: Codable, Equatable, Sendable {
    public struct Stamp: Codable, Equatable, Sendable {
        public var id: String
        public var at: Date
        public init(id: String, at: Date) {
            self.id = id
            self.at = at
        }
    }
    public struct RecordStamp: Codable, Equatable, Sendable {
        public var id: SyncRecordID
        public var at: Date
        public init(id: SyncRecordID, at: Date) {
            self.id = id
            self.at = at
        }
    }
    public struct Origin: Codable, Equatable, Sendable {
        public var id: SyncRecordID
        public var origin: String
        public var at: Date
        public init(id: SyncRecordID, origin: String, at: Date) {
            self.id = id
            self.origin = origin
            self.at = at
        }
    }

    public var deletedProfiles: [Stamp]
    public var deletedPlaylists: [Stamp]
    public var childTombstones: [RecordStamp]
    public var origins: [Origin]

    public init(deletedProfiles: [Stamp] = [], deletedPlaylists: [Stamp] = [],
                childTombstones: [RecordStamp] = [], origins: [Origin] = []) {
        self.deletedProfiles = deletedProfiles
        self.deletedPlaylists = deletedPlaylists
        self.childTombstones = childTombstones
        self.origins = origins
    }
}
