import Testing
import Foundation
import Core
import PlaybackCore
@testable import Personal

private func freshDefaults() -> UserDefaults {
    let name = "timestamp-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Styrbar klocka (ingen väggklocka i logiken).
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    func now() -> Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func item(_ id: String, _ kind: ContentKind = .movie) -> ItemRef { ItemRef(kind: kind, providerID: id) }

private func store(_ d: UserDefaults, _ c: Clock, key: String = "k", list: Int = 1000, ratings: Int = 2000) -> UserDefaultsPersonalStore {
    UserDefaultsPersonalStore(defaults: d, key: key, myListCapacity: list, ratingsCapacity: ratings, now: { c.now() })
}

private func snapshot(_ d: UserDefaults, key: String = "k") throws -> PersonalSnapshot {
    try JSONDecoder().decode(PersonalSnapshot.self, from: #require(d.data(forKey: key)))
}

@Test func legacyBlobsDecodeWithDistantPastTimestamps() throws {
    let json = """
    {"list":[{"kind":"movie","providerID":"a"},{"kind":"series","providerID":"b"}],
     "rated":[{"item":{"kind":"movie","providerID":"a"},"rating":"up"}],
     "favoriteChannels":["x","y"],"recentChannels":["r"]}
    """
    let snap = try JSONDecoder().decode(PersonalSnapshot.self, from: Data(json.utf8))
    #expect(snap.watchlist.count == 2)
    #expect(snap.watchlist.allSatisfy { $0.addedAt < Date(timeIntervalSince1970: 0) && $0.removedAt == nil })
    #expect(snap.watchlist[0].addedAt < snap.watchlist[1].addedAt)
    #expect(snap.ratingEntries.count == 1)
    #expect(snap.ratingEntries[0].rating == .up)
    #expect(snap.ratingEntries[0].updatedAt < Date(timeIntervalSince1970: 0))
    #expect(snap.favoriteEntries.map(\.id) == ["x", "y"])
    #expect(snap.favoriteEntries.allSatisfy { $0.updatedAt < Date(timeIntervalSince1970: 0) && $0.removedAt == nil })
    #expect(snap.recentChannels == ["r"])
}

@Test func legacyWatchlistOrderPreserved() {
    let d = freshDefaults()
    d.set(Data(#"{"list":[{"kind":"movie","providerID":"a"},{"kind":"movie","providerID":"b"},{"kind":"movie","providerID":"c"}],"rated":[]}"#.utf8), forKey: "k")
    let c = Clock(t0)
    let s = store(d, c)
    #expect(s.myList() == [item("c"), item("b"), item("a")])
    #expect(s.toggleMyList(item("n")) == true)
    #expect(s.myList().first == item("n"))
}

@Test func toggleOffLeavesTombstoneAndHidesItem() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c)
    _ = s.toggleMyList(item("a"))
    c.advance(10)
    #expect(s.toggleMyList(item("a")) == false)
    #expect(s.myList().isEmpty)
    #expect(s.isInMyList(item("a")) == false)
    let snap = try snapshot(d)
    #expect(snap.watchlist.count == 1)
    #expect(snap.watchlist[0].removedAt == c.now())
}

@Test func reAddingRevivesWithNewAddedAt() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c)
    _ = s.toggleMyList(item("a")); c.advance(1)
    _ = s.toggleMyList(item("b")); c.advance(1)
    _ = s.toggleMyList(item("a")); c.advance(1)
    #expect(s.toggleMyList(item("a")) == true)
    #expect(s.myList() == [item("a"), item("b")])
    let snap = try snapshot(d)
    let a = try #require(snap.watchlist.first { $0.item == item("a") })
    #expect(a.removedAt == nil)
    #expect(a.addedAt == c.now())
    #expect(snap.watchlist.count == 2)
}

@Test func watchlistOrderFollowsAddedAt() {
    let d = freshDefaults()
    let c = Clock(t0)
    // Blob där insättningsordningen avviker från addedAt.
    let json = """
    {"watchlist":[{"item":{"kind":"movie","providerID":"late"},"addedAt":2000},
                  {"item":{"kind":"movie","providerID":"early"},"addedAt":1000},
                  {"item":{"kind":"movie","providerID":"tieA"},"addedAt":3000},
                  {"item":{"kind":"movie","providerID":"tieB"},"addedAt":3000}]}
    """
    d.set(Data(json.utf8), forKey: "k")
    let s = store(d, c)
    #expect(s.myList() == [item("tieB"), item("tieA"), item("late"), item("early")])
}

@Test func capacityEvictsOldestLiveEntriesOnly() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c, list: 3)
    _ = s.toggleMyList(item("gone")); c.advance(1)
    _ = s.toggleMyList(item("gone")); c.advance(1)   // gravsten, äldst
    for id in ["a", "b", "c", "d"] { _ = s.toggleMyList(item(id)); c.advance(1) }
    #expect(s.myList() == [item("d"), item("c"), item("b")])
    let snap = try snapshot(d)
    #expect(snap.watchlist.filter { $0.removedAt != nil }.count == 2)   // gammal gravsten + utträngd "a"
    #expect(snap.watchlist.first { $0.item == item("a") }?.removedAt != nil)
    #expect(!s.isInMyList(item("a")))
    #expect(snap.watchlist.filter { $0.removedAt == nil }.count == 3)
}

@Test func capacityTieBreakIsByKeyString() {
    var snap = PersonalSnapshot()
    for id in ["b", "c", "a"] { snap.watchlist.append(WatchlistEntry(item: item(id), addedAt: t0)) }
    snap.enforceCapacity(watchlist: 2, ratings: 10, now: t0)
    #expect(Set(snap.liveWatchlist.map(\.providerID)) == ["b", "c"])
    #expect(snap.watchlist.first { $0.item == item("a") }?.removedAt == t0)
}

@Test func ratingsTombstoneOnSetNil() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c)
    s.setRating(.up, for: item("x")); c.advance(5)
    s.setRating(nil, for: item("x"))
    #expect(s.rating(item("x")) == nil)
    #expect(s.ratings().isEmpty)
    let snap = try snapshot(d)
    #expect(snap.ratingEntries.count == 1)
    #expect(snap.ratingEntries[0].rating == nil)
    #expect(snap.ratingEntries[0].updatedAt == c.now())
    s.setRating(nil, for: item("never"))
    #expect(try snapshot(d).ratingEntries.count == 1)
}

@Test func ratingsCapacityCountsLiveOnly() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c, ratings: 2)
    s.setRating(.up, for: item("t")); c.advance(1)
    s.setRating(nil, for: item("t")); c.advance(1)
    for id in ["a", "b", "c"] { s.setRating(.down, for: item(id)); c.advance(1) }
    #expect(Set(s.ratings().keys.map(\.providerID)) == ["b", "c"])
    let rs = try snapshot(d).ratingEntries
    #expect(rs.filter { $0.rating == nil }.count == 2)   // egen gravsten + utträngd "a"
    #expect(rs.first { $0.item == item("a") }?.rating == nil)
}

@Test func favoritesTombstone() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c)
    _ = s.toggleFavoriteChannel("a"); c.advance(1)
    _ = s.toggleFavoriteChannel("b"); c.advance(1)
    #expect(s.toggleFavoriteChannel("a") == false)
    #expect(s.favoriteChannels() == ["b"])
    let snap = try snapshot(d)
    #expect(snap.favoriteEntries.first { $0.id == "a" }?.removedAt == c.now())
    c.advance(1)
    #expect(s.toggleFavoriteChannel("a") == true)
    #expect(s.favoriteChannels() == ["a", "b"])
}

@Test func tombstonesPrunedAfterNinetyDays() throws {
    let d = freshDefaults()
    let c = Clock(t0)
    let s = store(d, c)
    _ = s.toggleMyList(item("a")); _ = s.toggleMyList(item("a"))
    s.setRating(.up, for: item("r")); s.setRating(nil, for: item("r"))
    _ = s.toggleFavoriteChannel("f"); _ = s.toggleFavoriteChannel("f")
    _ = s.toggleMyList(item("live"))
    c.advance(89 * 86400)
    let s89 = store(d, c)
    _ = s89.toggleMyList(item("poke")); _ = s89.toggleMyList(item("poke"))
    #expect(try snapshot(d).watchlist.contains { $0.item == item("a") })   // 89 dagar: kvar
    c.advance(2 * 86400)   // 91 dagar sedan första gravstenarna
    let s91 = store(d, c)
    _ = s91.toggleMyList(item("poke2"))
    let after = try snapshot(d)
    #expect(!after.watchlist.contains { $0.item == item("a") })
    #expect(after.watchlist.contains { $0.item == item("live") && $0.removedAt == nil })
    #expect(after.ratingEntries.isEmpty)
    #expect(!after.favoriteEntries.contains { $0.id == "f" })
    #expect(after.watchlist.contains { $0.item == item("poke") })   // färsk gravsten (2 dagar) finns kvar
}

@Test func pruneIsDeterministicOnSnapshot() {
    var snap = PersonalSnapshot()
    snap.watchlist = [WatchlistEntry(item: item("old"), addedAt: t0, removedAt: t0),
                      WatchlistEntry(item: item("new"), addedAt: t0, removedAt: t0.addingTimeInterval(86400))]
    snap.prune(now: t0.addingTimeInterval(90 * 86400 + 1))
    #expect(snap.watchlist.map(\.item.providerID) == ["new"])
}

@Test func profileEditBumpsUpdatedAt() {
    let c = Clock(t0)
    let playlist = UUID()
    let stores: [ProfileStore] = [InMemoryProfileStore(now: { c.now() }),
                                  UserDefaultsProfileStore(defaults: freshDefaults(), now: { c.now() })]
    for store in stores {
        c.advance(100)
        var p = Profile(playlistID: playlist, name: "A", avatar: "star", createdAt: c.now())
        store.save(p)
        #expect(store.profiles(playlistID: playlist)[0].updatedAt == p.createdAt)
        c.advance(100)
        store.save(p)   // oförändrad -> ingen bump
        #expect(store.profiles(playlistID: playlist)[0].updatedAt == p.createdAt)
        p.name = "B"
        store.save(p)
        #expect(store.profiles(playlistID: playlist)[0].updatedAt == c.now())
        let edits: [(inout Profile) -> Void] = [{ $0.avatar = "moon" }, { $0.isKids = true }, { $0.hasPin = true }]
        for edit in edits {
            c.advance(10)
            var q = store.profiles(playlistID: playlist)[0]
            edit(&q)
            store.save(q)
            #expect(store.profiles(playlistID: playlist)[0].updatedAt == c.now())
        }
    }
}

@Test func legacyProfileDecodesWithDistantPast() throws {
    let json = "{\"profiles\":[{\"id\":\"\(UUID())\",\"playlistID\":\"\(UUID())\",\"name\":\"Gammal\",\"avatar\":\"star\",\"isKids\":false,\"hasPin\":false,\"createdAt\":1000}],\"lastUsed\":[]}"
    let snap = try JSONDecoder().decode(ProfileSnapshot.self, from: Data(json.utf8))
    #expect(snap.profiles[0].updatedAt == .distantPast)
}

@Test func existingPublicAPIBehaviourUnchanged() {
    // Standardklockan fungerar som tidigare för befintliga anropare.
    let s = UserDefaultsPersonalStore(defaults: freshDefaults(), key: "k")
    let a = item("a"), b = item("b")
    #expect(s.toggleMyList(a)); #expect(s.toggleMyList(b))
    #expect(s.myList() == [b, a])
    #expect(!s.toggleMyList(a))
    s.setRating(.up, for: b)
    #expect(s.ratings() == [b: .up])
    #expect(s.toggleFavoriteChannel("f"))
    s.noteChannelWatched("r")
    #expect(s.recentChannels() == ["r"])
    let p = Profile(playlistID: UUID(), name: "N", avatar: "a")
    let ps = InMemoryProfileStore()
    ps.save(p)
    #expect(ps.profiles(playlistID: p.playlistID) == [p])
}
