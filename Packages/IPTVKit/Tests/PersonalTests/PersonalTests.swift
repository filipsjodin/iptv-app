import Testing
import Foundation
import Core
import PlaybackCore
@testable import Personal

private func freshDefaults() -> UserDefaults {
    let name = "personal-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func profile(_ playlist: UUID, _ name: String, at t: TimeInterval) -> Profile {
    Profile(id: UUID(), playlistID: playlist, name: name, avatar: "person.crop.circle",
            isKids: false, hasPin: false, createdAt: Date(timeIntervalSince1970: t))
}

@Test func profilesArePerPlaylistAndOrdered() {
    let a = UUID(), b = UUID()
    let stores: [ProfileStore] = [InMemoryProfileStore(), UserDefaultsProfileStore(defaults: freshDefaults())]
    for store in stores {
        let late = profile(a, "Sen", at: 200), early = profile(a, "Tidig", at: 100)
        let other = profile(b, "Annan", at: 50)
        store.save(late); store.save(early); store.save(other)
        #expect(store.profiles(playlistID: a).map(\.name) == ["Tidig", "Sen"])
        #expect(store.profiles(playlistID: b).map(\.name) == ["Annan"])
        store.setLastUsed(late.id, playlistID: a)
        #expect(store.lastUsed(playlistID: a) == late.id)
        #expect(store.lastUsed(playlistID: b) == nil)
        store.delete(id: late.id)
        #expect(store.profiles(playlistID: a).count == 1)
        #expect(store.lastUsed(playlistID: a) == nil)
    }
}

@Test func myListToggleAndOrder() {
    let store = UserDefaultsPersonalStore(defaults: freshDefaults(), key: "personal.v1.x")
    let a = ItemRef(kind: .movie, providerID: "a"), b = ItemRef(kind: .series, providerID: "b")
    #expect(store.toggleMyList(a) == true)
    #expect(store.toggleMyList(b) == true)
    #expect(store.myList() == [b, a])
    #expect(store.toggleMyList(a) == false)
    #expect(store.myList() == [b])
    #expect(store.isInMyList(a) == false)
    #expect(store.isInMyList(b) == true)
}

@Test func ratingsSetAndClear() {
    let store = UserDefaultsPersonalStore(defaults: freshDefaults(), key: "personal.v1.x")
    let x = ItemRef(kind: .movie, providerID: "x")
    store.setRating(.up, for: x)
    #expect(store.rating(x) == .up)
    #expect(store.ratings() == [x: .up])
    store.setRating(.down, for: x)
    #expect(store.rating(x) == .down)
    store.setRating(nil, for: x)
    #expect(store.rating(x) == nil)
    #expect(store.ratings().isEmpty)
}

@Test func personalStoresAreIsolatedPerProfile() {
    let d = freshDefaults()
    let p1 = UUID(), p2 = UUID()
    let s1 = UserDefaultsPersonalStore(defaults: d, key: ProfileKeys.personal(p1))
    let s2 = UserDefaultsPersonalStore(defaults: d, key: ProfileKeys.personal(p2))
    let x = ItemRef(kind: .movie, providerID: "x")
    _ = s1.toggleMyList(x); s1.setRating(.up, for: x)
    #expect(s2.myList().isEmpty)
    #expect(s2.rating(x) == nil)
    let again = UserDefaultsPersonalStore(defaults: d, key: ProfileKeys.personal(p1))
    #expect(again.isInMyList(x))
    #expect(ProfileKeys.progress(p1) == "userstate.progress.v1.\(p1)")
    #expect(ProfileKeys.settings(p1) == "settings.playback.v1.\(p1)")
    #expect(ProfileKeys.personal(p1) == "personal.v1.\(p1)")
}

@Test func capacitiesAreEnforced() {
    let store = UserDefaultsPersonalStore(defaults: freshDefaults(), key: "k", myListCapacity: 5, ratingsCapacity: 10)
    for i in 0..<8 { _ = store.toggleMyList(ItemRef(kind: .movie, providerID: "m\(i)")) }
    #expect(store.myList().count == 5)
    #expect(store.myList().first?.providerID == "m7")
    for i in 0..<13 { store.setRating(.up, for: ItemRef(kind: .movie, providerID: "r\(i)")) }
    #expect(store.ratings().count == 10)
    #expect(store.rating(ItemRef(kind: .movie, providerID: "r12")) == .up)
    #expect(store.rating(ItemRef(kind: .movie, providerID: "r0")) == nil)
}

private func seedLegacy(_ d: UserDefaults, a: UUID, b: UUID) {
    let legacy = UserDefaultsUserStateStore(defaults: d)
    let t = Date(timeIntervalSince1970: 1000)
    legacy.save(WatchProgress(key: ProgressKey(playlistID: a, kind: .movie, providerID: "ma"), position: 100, duration: 1000, watched: false, updatedAt: t))
    legacy.save(WatchProgress(key: ProgressKey(playlistID: b, kind: .movie, providerID: "mb"), position: 200, duration: 1000, watched: false, updatedAt: t))
    var s = PlaybackSettings(); s.previewsEnabled = false
    s.save(to: d)
}

@Test func legacyMigrationMovesProgressPerPlaylist() throws {
    let d = freshDefaults()
    let a = UUID(), b = UUID()
    seedLegacy(d, a: a, b: b)
    let store = InMemoryProfileStore()
    let result = ProfileMigration.migrateLegacy(defaults: d, playlists: [a, b], profiles: store)
    #expect(result.count == 2)
    let pa = try #require(store.profiles(playlistID: a).first)
    let pb = try #require(store.profiles(playlistID: b).first)
    #expect(pa.name == "Profil 1"); #expect(pa.avatar == "person.crop.circle")
    #expect(result[a] == pa); #expect(result[b] == pb)

    let sa = UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(pa.id))
    let sb = UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(pb.id))
    #expect(sa.allEntries().map(\.key.providerID) == ["ma"])
    #expect(sb.allEntries().map(\.key.providerID) == ["mb"])
    #expect(PlaybackSettings.load(from: d, key: ProfileKeys.settings(pa.id)).previewsEnabled == false)
    #expect(PlaybackSettings.load(from: d, key: ProfileKeys.settings(pb.id)).previewsEnabled == false)
    #expect(d.data(forKey: "userstate.progress.v1") == nil)
    #expect(d.data(forKey: "settings.playback.v1") == nil)
}

@Test func legacyMigrationIsIdempotent() {
    let d = freshDefaults()
    let a = UUID(), b = UUID()
    seedLegacy(d, a: a, b: b)
    let store = InMemoryProfileStore()
    _ = ProfileMigration.migrateLegacy(defaults: d, playlists: [a, b], profiles: store)
    let first = store.profiles(playlistID: a)
    let second = ProfileMigration.migrateLegacy(defaults: d, playlists: [a, b], profiles: store)
    #expect(second.isEmpty)
    #expect(store.profiles(playlistID: a) == first)
    #expect(store.profiles(playlistID: b).count == 1)
    let sa = UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(first[0].id))
    #expect(sa.allEntries().count == 1)
}

@Test func pinStoreVerifies() throws {
    let store = InMemoryProfilePinStore()
    let id = UUID()
    #expect(try store.verify("1234", profileID: id) == false)
    try store.setPin("1234", profileID: id)
    #expect(try store.verify("1234", profileID: id) == true)
    #expect(try store.verify("0000", profileID: id) == false)
    try store.removePin(profileID: id)
    #expect(try store.verify("1234", profileID: id) == false)
    try store.setPin("1234", profileID: id)
    try store.setPin(nil, profileID: id)
    #expect(try store.verify("1234", profileID: id) == false)
}

@Test func corruptDataYieldsEmpty() {
    let d = freshDefaults()
    let junk = Data("not json{".utf8)
    d.set(junk, forKey: "profiles.v1")
    d.set(junk, forKey: "personal.v1.x")
    let ps = UserDefaultsProfileStore(defaults: d)
    #expect(ps.profiles(playlistID: UUID()).isEmpty)
    #expect(ps.lastUsed(playlistID: UUID()) == nil)
    let pe = UserDefaultsPersonalStore(defaults: d, key: "personal.v1.x")
    #expect(pe.myList().isEmpty)
    #expect(pe.ratings().isEmpty)
    #expect(pe.toggleMyList(ItemRef(kind: .live, providerID: "l")) == true)
}

private func progress(_ d: UserDefaults, key: String? = nil, playlist: UUID, id: String) {
    let store = key.map { UserDefaultsUserStateStore(defaults: d, key: $0) } ?? UserDefaultsUserStateStore(defaults: d)
    store.save(WatchProgress(key: ProgressKey(playlistID: playlist, kind: .movie, providerID: id), position: 50, duration: 500, watched: false, updatedAt: Date(timeIntervalSince1970: 1000)))
}

@Test func migrationKeepsLegacyForPlaylistsNotPassed() throws {
    let d = freshDefaults()
    let a = UUID(), b = UUID()
    seedLegacy(d, a: a, b: b)
    let store = InMemoryProfileStore()
    _ = ProfileMigration.migrateLegacy(defaults: d, playlists: [a], profiles: store)
    #expect(store.profiles(playlistID: a).count == 1)
    #expect(store.profiles(playlistID: b).isEmpty)
    let remaining = UserDefaultsUserStateStore(defaults: d, key: "userstate.progress.v1")
    #expect(remaining.allEntries().map(\.key.providerID) == ["mb"])

    _ = ProfileMigration.migrateLegacy(defaults: d, playlists: [a, b], profiles: store)
    let pb = try #require(store.profiles(playlistID: b).first)
    let sb = UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(pb.id))
    #expect(sb.allEntries().map(\.key.providerID) == ["mb"])
    #expect(d.data(forKey: "userstate.progress.v1") == nil)
}

@Test func migrationLeavesExistingProfileUntouched() throws {
    let d = freshDefaults()
    let a = UUID(), b = UUID()
    let store = InMemoryProfileStore()
    let existing = Profile(playlistID: a, name: "Mamma", avatar: "star")
    store.save(existing)
    progress(d, key: ProfileKeys.progress(existing.id), playlist: a, id: "own")
    seedLegacy(d, a: a, b: b)
    let result = ProfileMigration.migrateLegacy(defaults: d, playlists: [a, b], profiles: store)
    #expect(result.keys.sorted { $0.uuidString < $1.uuidString } == [b])
    #expect(store.profiles(playlistID: a) == [existing])
    let own = UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(existing.id))
    #expect(own.allEntries().map(\.key.providerID) == ["own"])
    let pb = try #require(store.profiles(playlistID: b).first)
    #expect(UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(pb.id)).allEntries().map(\.key.providerID) == ["mb"])
}

@Test func migrationSurvivesCorruptLegacyData() throws {
    let d = freshDefaults()
    let a = UUID()
    d.set(Data("junk{".utf8), forKey: "userstate.progress.v1")
    d.set(Data("junk{".utf8), forKey: "settings.playback.v1")
    let store = InMemoryProfileStore()
    let result = ProfileMigration.migrateLegacy(defaults: d, playlists: [a], profiles: store)
    let p = try #require(result[a])
    #expect(store.profiles(playlistID: a) == [p])
    #expect(UserDefaultsUserStateStore(defaults: d, key: ProfileKeys.progress(p.id)).allEntries().isEmpty)
    #expect(PlaybackSettings.load(from: d, key: ProfileKeys.settings(p.id)) == PlaybackSettings())
}
