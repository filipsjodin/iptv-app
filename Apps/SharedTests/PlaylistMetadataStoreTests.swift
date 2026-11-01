import Core
import Foundation
import Testing
@testable import IPTVApp

private let day: TimeInterval = 24 * 60 * 60
private let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
private let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

@MainActor
private final class TestClock {
    var now: Date
    init(_ seconds: TimeInterval) { now = Date(timeIntervalSince1970: seconds) }
}

@MainActor
private func makeStore(_ clock: TestClock, defaults: UserDefaults = freshDefaults()) -> PlaylistMetadataStore {
    PlaylistMetadataStore(defaults: defaults, now: { clock.now })
}

private func playlist(_ id: UUID, name: String = "P") -> Playlist {
    Playlist(id: id, name: name, kind: .xtream, createdAt: Date(timeIntervalSince1970: 100))
}

@MainActor
@Test func savedPlaylistGetsUpdatedAt() {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    store.save(playlist(idA))
    #expect(store.all().first?.updatedAt == Date(timeIntervalSince1970: 5000))
    #expect(store.all().first?.fromRemote == false)
}

@MainActor
@Test func legacyBlobDecodesWithDistantPast() throws {
    let defaults = freshDefaults()
    // En äldre blob saknar synkfälten helt (samma form som den gamla kodningen).
    let encoder = JSONEncoder()
    let blob = try encoder.encode([LegacyEntry(id: idA, name: "Gammal", kind: .xtream,
                                                createdAt: Date(timeIntervalSinceReferenceDate: 1000))])
    defaults.set(blob, forKey: PlaylistMetadataStore.key)

    let store = PlaylistMetadataStore(defaults: defaults)
    let entry = try #require(store.all().first)
    #expect(entry.id == idA && entry.name == "Gammal")
    #expect(entry.updatedAt == .distantPast)
    #expect(entry.deletedAt == nil && entry.fromRemote == false)
}

private struct LegacyEntry: Codable {
    var id: UUID
    var name: String
    var kind: PlaylistSourceKind
    var createdAt: Date
}

@MainActor
@Test func removedPlaylistLeavesTombstone() {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    store.save(playlist(idA))
    store.save(playlist(idB))
    clock.now = Date(timeIntervalSince1970: 6000)
    store.remove([idA])

    #expect(store.all().map(\.id) == [idB])  // all() döljer gravstenar
    let tomb = store.allIncludingTombstones().first { $0.id == idA }
    #expect(tomb?.deletedAt == Date(timeIntervalSince1970: 6000))
    #expect(tomb?.updatedAt == Date(timeIntervalSince1970: 6000))
    #expect(store.allIncludingTombstones().count == 2)
}

@MainActor
@Test func removingUnknownIDLeavesNoTombstone() {
    let store = makeStore(TestClock(5000))
    store.remove([idA])
    #expect(store.allIncludingTombstones().isEmpty)
}

@MainActor
@Test func tombstonePrunedAfter90Days() {
    let clock = TestClock(0)
    let store = makeStore(clock)
    store.save(playlist(idA))
    store.remove([idA])
    clock.now = Date(timeIntervalSince1970: 89 * day)
    store.pruneTombstones()
    #expect(store.allIncludingTombstones().count == 1)
    clock.now = Date(timeIntervalSince1970: 91 * day)
    store.save(playlist(idB))  // varje skrivning prunar
    #expect(store.allIncludingTombstones().map(\.id) == [idB])
}

@MainActor
@Test func remoteOnlyPlaylistShowsMissingCredentialsState() throws {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    let changed = store.applyRemote(id: idA, name: "Från iPhone", kind: .m3u,
                                    createdAt: Date(timeIntervalSince1970: 100),
                                    updatedAt: Date(timeIntervalSince1970: 4000))
    #expect(changed)
    let entry = try #require(store.all().first)  // syns i listan
    #expect(entry.id == idA && entry.name == "Från iPhone" && entry.kind == .m3u)
    #expect(entry.fromRemote && entry.isRemoteOnly)
    #expect(entry.updatedAt == Date(timeIntervalSince1970: 4000))

    // När användaren loggat in lokalt sparas spellistan och läget försvinner.
    store.save(playlist(idA, name: "Från iPhone"))
    #expect(store.all().first?.isRemoteOnly == false)
}

@MainActor
@Test func applyRemoteOlderIgnoredNewerWins() throws {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    store.save(playlist(idA, name: "Lokal"))  // updatedAt 5000
    #expect(store.applyRemote(id: idA, name: "Äldre", kind: .xtream, createdAt: Date(timeIntervalSince1970: 100),
                              updatedAt: Date(timeIntervalSince1970: 4000)) == false)
    #expect(store.applyRemote(id: idA, name: "Lika", kind: .xtream, createdAt: Date(timeIntervalSince1970: 100),
                              updatedAt: Date(timeIntervalSince1970: 5000)) == false)
    #expect(store.all().first?.name == "Lokal")

    #expect(store.applyRemote(id: idA, name: "Nyare", kind: .xtream, createdAt: Date(timeIntervalSince1970: 100),
                              updatedAt: Date(timeIntervalSince1970: 6000)))
    let entry = try #require(store.all().first)
    #expect(entry.name == "Nyare" && entry.updatedAt == Date(timeIntervalSince1970: 6000))
    #expect(entry.fromRemote == false)  // lokal inloggning finns kvar
}

@MainActor
@Test func remoteTombstoneMarksLiveEntryOnlyIfNotOlderThanLocal() {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    store.save(playlist(idA))  // updatedAt 5000

    // Äldre gravsten än lokal ändring: ignoreras.
    #expect(store.applyRemoteTombstone(id: idA, deletedAt: Date(timeIntervalSince1970: 4000)) == false)
    #expect(store.all().map(\.id) == [idA])
    #expect(store.pendingRemoteDeletions().isEmpty)

    // Lika ny eller nyare: markeras och flaggas för lokal städning.
    #expect(store.applyRemoteTombstone(id: idA, deletedAt: Date(timeIntervalSince1970: 5000)))
    #expect(store.all().isEmpty)
    #expect(store.pendingRemoteDeletions() == [idA])
    store.markRemoteDeletionHandled([idA])
    #expect(store.pendingRemoteDeletions().isEmpty)
    #expect(store.allIncludingTombstones().count == 1)

    // Okänt id och redan raderad post ignoreras.
    #expect(store.applyRemoteTombstone(id: idB, deletedAt: Date(timeIntervalSince1970: 9000)) == false)
    #expect(store.applyRemoteTombstone(id: idA, deletedAt: Date(timeIntervalSince1970: 9000)) == false)
}

@MainActor
@Test func newerRemoteLiveEntryResurrectsTombstoneAsRemoteOnly() throws {
    let clock = TestClock(5000)
    let store = makeStore(clock)
    store.save(playlist(idA))
    store.remove([idA])  // gravsten vid 5000
    #expect(store.applyRemote(id: idA, name: "X", kind: .xtream, createdAt: Date(timeIntervalSince1970: 100),
                              updatedAt: Date(timeIntervalSince1970: 4000)) == false)
    #expect(store.applyRemote(id: idA, name: "X", kind: .xtream, createdAt: Date(timeIntervalSince1970: 100),
                              updatedAt: Date(timeIntervalSince1970: 7000)))
    let entry = try #require(store.all().first)
    #expect(entry.isRemoteOnly && entry.deletedAt == nil)
}
