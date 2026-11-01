import Foundation
import Core

public struct ItemRef: Codable, Hashable, Sendable {
    public var kind: ContentKind
    public var providerID: String
    public init(kind: ContentKind, providerID: String) {
        self.kind = kind
        self.providerID = providerID
    }
}

public enum Rating: String, Codable, Sendable { case up, down }

public protocol PersonalStore: Sendable {
    /// Nyast först.
    func myList() -> [ItemRef]
    /// Returnerar `true` om posten finns i listan efter anropet.
    func toggleMyList(_ item: ItemRef) -> Bool
    func isInMyList(_ item: ItemRef) -> Bool
    func rating(_ item: ItemRef) -> Rating?
    func setRating(_ rating: Rating?, for item: ItemRef)
    func ratings() -> [ItemRef: Rating]
    /// Favoritkanaler (kanalgrupp-id), nyast först.
    func favoriteChannels() -> [String]
    /// Returnerar `true` om kanalen är favorit efter anropet.
    func toggleFavoriteChannel(_ groupID: String) -> Bool
    /// Senast sedda kanaler, nyast först, högst 20.
    func recentChannels() -> [String]
    /// Flyttar kanalen först; dubbletter tas bort.
    func noteChannelWatched(_ groupID: String)
}

/// Min lista-post. `removedAt != nil` är en gravsten (synkroniseringen behöver veta att posten togs bort).
struct WatchlistEntry: Codable, Equatable {
    var item: ItemRef
    var addedAt: Date
    var removedAt: Date?
    init(item: ItemRef, addedAt: Date, removedAt: Date? = nil) {
        self.item = item
        self.addedAt = addedAt
        self.removedAt = removedAt
    }
    var isLive: Bool { removedAt == nil }
}

/// Betyg; `rating == nil` är en gravsten. Saknad `updatedAt` (gammal blob) = `Date.distantPast`.
struct RatingEntry: Codable, Equatable {
    var item: ItemRef
    var rating: Rating?
    var updatedAt: Date
    init(item: ItemRef, rating: Rating?, updatedAt: Date) {
        self.item = item
        self.rating = rating
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case item, rating, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(ItemRef.self, forKey: .item)
        rating = try c.decodeIfPresent(Rating.self, forKey: .rating)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
    var isLive: Bool { rating != nil }
}

/// Favoritkanal; `removedAt != nil` är en gravsten. `updatedAt` är tillfället då favoriten senast lades till/togs bort.
struct FavoriteChannelEntry: Codable, Equatable {
    var id: String
    var updatedAt: Date
    var removedAt: Date?
    init(id: String, updatedAt: Date, removedAt: Date? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.removedAt = removedAt
    }
    var isLive: Bool { removedAt == nil }
}

struct PersonalSnapshot: Codable {
    /// Gravstenar sparas så här länge innan `prune(now:)` rensar dem.
    static let tombstoneLifetime: TimeInterval = 90 * 86400

    /// Insättningsordning (nyast sist); visningsordningen följer `addedAt` med insättningsordning som tie-break.
    var watchlist: [WatchlistEntry] = []
    var ratingEntries: [RatingEntry] = []
    var favoriteEntries: [FavoriteChannelEntry] = []
    /// Äldst först (nyast sist); `recentChannels()` vänder ordningen. Enhetslokal, synkas inte.
    var recentChannels: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case watchlist, ratingEntries, favoriteEntries, recentChannels
        // Äldre format utan tidsstämplar (läses, skrivs aldrig).
        case list, rated, favoriteChannels
    }

    /// Syntetisk tidsstämpel för äldre poster: strikt växande med index och äldre än alla riktiga tidsstämplar.
    private static func legacyDate(_ index: Int) -> Date { Date.distantPast.addingTimeInterval(TimeInterval(index)) }

    // Gamla blobbar saknar fält: `decodeIfPresent` med standardvärde; äldre arrayer får distantPast-tidsstämplar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let w = try c.decodeIfPresent([WatchlistEntry].self, forKey: .watchlist) {
            watchlist = w
        } else {
            let old = try c.decodeIfPresent([ItemRef].self, forKey: .list) ?? []
            watchlist = old.enumerated().map { WatchlistEntry(item: $1, addedAt: Self.legacyDate($0)) }
        }
        if let r = try c.decodeIfPresent([RatingEntry].self, forKey: .ratingEntries) {
            ratingEntries = r
        } else {
            let old = try c.decodeIfPresent([RatingEntry].self, forKey: .rated) ?? []
            ratingEntries = old.enumerated().map {
                RatingEntry(item: $1.item, rating: $1.rating, updatedAt: Self.legacyDate($0))
            }
        }
        if let f = try c.decodeIfPresent([FavoriteChannelEntry].self, forKey: .favoriteEntries) {
            favoriteEntries = f
        } else {
            let old = try c.decodeIfPresent([String].self, forKey: .favoriteChannels) ?? []
            favoriteEntries = old.enumerated().map { FavoriteChannelEntry(id: $1, updatedAt: Self.legacyDate($0)) }
        }
        recentChannels = try c.decodeIfPresent([String].self, forKey: .recentChannels) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(ratingEntries, forKey: .ratingEntries)
        try c.encode(favoriteEntries, forKey: .favoriteEntries)
        try c.encode(recentChannels, forKey: .recentChannels)
    }

    // MARK: Läsning (gravstenar dolda)

    /// Äldst först efter `addedAt`, insättningsordning som stabil tie-break.
    var liveWatchlist: [ItemRef] {
        watchlist.enumerated().filter { $0.element.isLive }
            .sorted { ($0.element.addedAt, $0.offset) < ($1.element.addedAt, $1.offset) }
            .map(\.element.item)
    }

    /// Äldst först efter `updatedAt`, insättningsordning som stabil tie-break.
    var liveFavorites: [String] {
        favoriteEntries.enumerated().filter { $0.element.isLive }
            .sorted { ($0.element.updatedAt, $0.offset) < ($1.element.updatedAt, $1.offset) }
            .map(\.element.id)
    }

    // MARK: Skrivning

    /// Returnerar `true` om posten är levande efter anropet. Återinsättning av en gravsten återupplivar den med nytt `addedAt`.
    mutating func toggleWatchlist(_ item: ItemRef, now: Date) -> Bool {
        if let i = watchlist.firstIndex(where: { $0.item == item }) {
            var e = watchlist.remove(at: i)
            if e.isLive {
                e.removedAt = now
                watchlist.append(e)
                return false
            }
        }
        watchlist.append(WatchlistEntry(item: item, addedAt: now))
        return true
    }

    mutating func setRating(_ rating: Rating?, for item: ItemRef, now: Date) {
        let i = ratingEntries.firstIndex { $0.item == item }
        // Att rensa ett betyg som aldrig fanns lämnar ingen gravsten.
        if rating == nil, i == nil || ratingEntries[i!].rating == nil { return }
        if let i { ratingEntries.remove(at: i) }
        ratingEntries.append(RatingEntry(item: item, rating: rating, updatedAt: now))
    }

    mutating func toggleFavorite(_ id: String, now: Date) -> Bool {
        if let i = favoriteEntries.firstIndex(where: { $0.id == id }) {
            var e = favoriteEntries.remove(at: i)
            if e.isLive {
                e.updatedAt = now
                e.removedAt = now
                favoriteEntries.append(e)
                return false
            }
        }
        favoriteEntries.append(FavoriteChannelEntry(id: id, updatedAt: now))
        return true
    }

    // MARK: Underhåll

    /// Rensar gravstenar äldre än 90 dagar.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        watchlist.removeAll { ($0.removedAt ?? .distantFuture) < cutoff }
        ratingEntries.removeAll { $0.rating == nil && $0.updatedAt < cutoff }
        favoriteEntries.removeAll { ($0.removedAt ?? .distantFuture) < cutoff }
    }

    private static func key(_ item: ItemRef) -> String { "\(item.kind.rawValue)|\(item.providerID)" }

    /// Kapaciteten gäller levande poster; äldst tidsstämpel först, key-sträng som deterministisk tie-break
    /// (samma regel på alla enheter). Gravstenar påverkas inte.
    mutating func enforceCapacity(watchlist wCap: Int, ratings rCap: Int) {
        let liveW = watchlist.filter(\.isLive)
        if liveW.count > wCap {
            let drop = Set(liveW
                .sorted { ($0.addedAt, Self.key($0.item)) < ($1.addedAt, Self.key($1.item)) }
                .prefix(liveW.count - wCap).map(\.item))
            watchlist.removeAll { $0.isLive && drop.contains($0.item) }
        }
        let liveR = ratingEntries.filter(\.isLive)
        if liveR.count > rCap {
            let drop = Set(liveR
                .sorted { ($0.updatedAt, Self.key($0.item)) < ($1.updatedAt, Self.key($1.item)) }
                .prefix(liveR.count - rCap).map(\.item))
            ratingEntries.removeAll { $0.isLive && drop.contains($0.item) }
        }
    }
}

public final class UserDefaultsPersonalStore: PersonalStore, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults är trådsäkert men inte annoterat Sendable på alla plattformar;
    // `snap` skyddas av `lock`. En JSON-blob under `key`; skadad data ger tomma listor.
    public static let defaultMyListCapacity = 1000
    public static let defaultRatingsCapacity = 2000
    public static let recentChannelsCapacity = 20
    private let myListCapacity: Int
    private let ratingsCapacity: Int
    private let now: @Sendable () -> Date

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var snap: PersonalSnapshot

    public convenience init(defaults: UserDefaults, key: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(defaults: defaults, key: key, myListCapacity: Self.defaultMyListCapacity,
                  ratingsCapacity: Self.defaultRatingsCapacity, now: now)
    }

    /// Intern: injicerbara kapaciteter (för tester). Gravstenar äldre än 90 dagar rensas vid laddning.
    init(defaults: UserDefaults, key: String, myListCapacity: Int, ratingsCapacity: Int,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.myListCapacity = myListCapacity
        self.ratingsCapacity = ratingsCapacity
        self.now = now
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(PersonalSnapshot.self, from: data) {
            snap = s
        } else {
            snap = PersonalSnapshot()
        }
        snap.prune(now: now())
    }

    /// Rensar gravstenar och tillämpar kapaciteten; körs före varje skrivning.
    private func persist() {
        snap.prune(now: now())
        snap.enforceCapacity(watchlist: myListCapacity, ratings: ratingsCapacity)
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: key) }
    }

    public func myList() -> [ItemRef] { lock.withLock { Array(snap.liveWatchlist.reversed()) } }

    public func toggleMyList(_ item: ItemRef) -> Bool {
        lock.withLock {
            defer { persist() }
            return snap.toggleWatchlist(item, now: now())
        }
    }

    public func isInMyList(_ item: ItemRef) -> Bool {
        lock.withLock { snap.watchlist.contains { $0.item == item && $0.isLive } }
    }

    public func rating(_ item: ItemRef) -> Rating? {
        lock.withLock { snap.ratingEntries.first { $0.item == item }?.rating }
    }

    public func setRating(_ rating: Rating?, for item: ItemRef) {
        lock.withLock {
            snap.setRating(rating, for: item, now: now())
            persist()
        }
    }

    public func ratings() -> [ItemRef: Rating] {
        lock.withLock {
            Dictionary(snap.ratingEntries.compactMap { e in e.rating.map { (e.item, $0) } }, uniquingKeysWith: { $1 })
        }
    }

    public func favoriteChannels() -> [String] { lock.withLock { Array(snap.liveFavorites.reversed()) } }

    public func toggleFavoriteChannel(_ groupID: String) -> Bool {
        lock.withLock {
            defer { persist() }
            return snap.toggleFavorite(groupID, now: now())
        }
    }

    public func recentChannels() -> [String] { lock.withLock { Array(snap.recentChannels.reversed()) } }

    public func noteChannelWatched(_ groupID: String) {
        lock.withLock {
            snap.recentChannels.removeAll { $0 == groupID }
            snap.recentChannels.append(groupID)
            let cap = Self.recentChannelsCapacity
            if snap.recentChannels.count > cap { snap.recentChannels.removeFirst(snap.recentChannels.count - cap) }
            persist()
        }
    }
}
