import Foundation

/// En profil inom en spellista. PIN-koden lagras aldrig här (se `ProfilePinStore`).
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var playlistID: UUID
    public var name: String
    /// Namn på en SF Symbol eller en emoji.
    public var avatar: String
    public var isKids: Bool
    public var hasPin: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), playlistID: UUID, name: String, avatar: String,
                isKids: Bool = false, hasPin: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.playlistID = playlistID
        self.name = name
        self.avatar = avatar
        self.isKids = isKids
        self.hasPin = hasPin
        self.createdAt = createdAt
    }
}

public protocol ProfileStore: Sendable {
    /// Spellistans profiler, äldst först.
    func profiles(playlistID: UUID) -> [Profile]
    func save(_ profile: Profile)
    func delete(id: UUID)
    func lastUsed(playlistID: UUID) -> UUID?
    func setLastUsed(_ id: UUID, playlistID: UUID)
}

struct ProfileSnapshot: Codable {
    var profiles: [Profile] = []
    var lastUsed: [UUID: UUID] = [:]

    func profiles(playlistID: UUID) -> [Profile] {
        profiles.filter { $0.playlistID == playlistID }.sorted { $0.createdAt < $1.createdAt }
    }

    mutating func save(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
    }

    mutating func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        for (k, v) in lastUsed where v == id { lastUsed[k] = nil }
    }

    // Dictionary med UUID-nycklar kodas av Codable som en växlande array; koda som lista av par istället.
    private enum CodingKeys: String, CodingKey { case profiles, lastUsed }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        let pairs = try c.decodeIfPresent([[UUID]].self, forKey: .lastUsed) ?? []
        for p in pairs where p.count == 2 { lastUsed[p[0]] = p[1] }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(lastUsed.map { [$0.key, $0.value] }, forKey: .lastUsed)
    }
}

public final class InMemoryProfileStore: ProfileStore, @unchecked Sendable {
    // @unchecked Sendable: allt muterbart state skyddas av `lock`.
    private let lock = NSLock()
    private var snap = ProfileSnapshot()
    public init() {}

    public func profiles(playlistID: UUID) -> [Profile] { lock.withLock { snap.profiles(playlistID: playlistID) } }
    public func save(_ profile: Profile) { lock.withLock { snap.save(profile) } }
    public func delete(id: UUID) { lock.withLock { snap.delete(id: id) } }
    public func lastUsed(playlistID: UUID) -> UUID? { lock.withLock { snap.lastUsed[playlistID] } }
    public func setLastUsed(_ id: UUID, playlistID: UUID) { lock.withLock { snap.lastUsed[playlistID] = id } }
}

public final class UserDefaultsProfileStore: ProfileStore, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults är trådsäkert men inte annoterat Sendable på alla plattformar;
    // `snap` skyddas av `lock`. En JSON-blob under `key`; skadad data ger tomt lager.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var snap: ProfileSnapshot

    public init(defaults: UserDefaults, key: String = "profiles.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(ProfileSnapshot.self, from: data) {
            snap = s
        } else {
            snap = ProfileSnapshot()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: key) }
    }

    public func profiles(playlistID: UUID) -> [Profile] { lock.withLock { snap.profiles(playlistID: playlistID) } }
    public func save(_ profile: Profile) { lock.withLock { snap.save(profile); persist() } }
    public func delete(id: UUID) { lock.withLock { snap.delete(id: id); persist() } }
    public func lastUsed(playlistID: UUID) -> UUID? { lock.withLock { snap.lastUsed[playlistID] } }
    public func setLastUsed(_ id: UUID, playlistID: UUID) {
        lock.withLock { snap.lastUsed[playlistID] = id; persist() }
    }
}
