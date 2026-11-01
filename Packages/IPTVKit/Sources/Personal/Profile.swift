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
    /// Senaste ändring av namn, avatar, barnprofil eller PIN-flagga (sätts av `ProfileStore.save`).
    /// Saknas i gamla blobbar och blir då `Date.distantPast`. Används av synkroniseringen (senaste vinner).
    public var updatedAt: Date

    /// `updatedAt` utelämnat = `createdAt` (en ny profil är "ändrad" när den skapas).
    public init(id: UUID = UUID(), playlistID: UUID, name: String, avatar: String,
                isKids: Bool = false, hasPin: Bool = false, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.playlistID = playlistID
        self.name = name
        self.avatar = avatar
        self.isKids = isKids
        self.hasPin = hasPin
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, playlistID, name, avatar, isKids, hasPin, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        playlistID = try c.decode(UUID.self, forKey: .playlistID)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decode(String.self, forKey: .avatar)
        isKids = try c.decode(Bool.self, forKey: .isKids)
        hasPin = try c.decode(Bool.self, forKey: .hasPin)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Samma redigerbara innehåll (utan tidsstämplar).
    func sameContent(as other: Profile) -> Bool {
        name == other.name && avatar == other.avatar && isKids == other.isKids && hasPin == other.hasPin
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

    /// En ändrad profil (namn, avatar, isKids, hasPin) får `updatedAt = now`; en oförändrad eller ny sparas som den är.
    mutating func save(_ p: Profile, now: Date) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            var next = p
            if !p.sameContent(as: profiles[i]) { next.updatedAt = now }
            profiles[i] = next
        } else {
            profiles.append(p)
        }
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
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func profiles(playlistID: UUID) -> [Profile] { lock.withLock { snap.profiles(playlistID: playlistID) } }
    public func save(_ profile: Profile) { lock.withLock { snap.save(profile, now: now()) } }
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
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults, key: String = "profiles.v1", now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
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
    public func save(_ profile: Profile) { lock.withLock { snap.save(profile, now: now()); persist() } }
    public func delete(id: UUID) { lock.withLock { snap.delete(id: id); persist() } }
    public func lastUsed(playlistID: UUID) -> UUID? { lock.withLock { snap.lastUsed[playlistID] } }
    public func setLastUsed(_ id: UUID, playlistID: UUID) {
        lock.withLock { snap.lastUsed[playlistID] = id; persist() }
    }
}
