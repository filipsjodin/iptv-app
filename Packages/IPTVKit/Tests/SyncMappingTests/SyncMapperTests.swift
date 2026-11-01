import Testing
import Foundation
import Core
import Personal
import PlaybackCore
import Sync
@testable import SyncMapping

/// Rikt tillstånd: profil, spellista, framsteg, min lista, betyg, favoriter, inställningar, textförskjutning.
private func richState(device: String = "A") -> SyncableState {
    var s = SyncableState(deviceID: device)
    let p = uuid(1)
    let playlist = Playlist(id: uuid(100), name: "Min lista", kind: .xtream, createdAt: at(0))
    // Hemligheten finns "nära" men ingår aldrig i tillståndet.
    let secret = PlaylistSecret.xtream(server: URL(string: "http://secret.example:8080")!, username: "anna", password: "hunter2")
    _ = secret
    s.playlists[playlist.id] = PlaylistMeta(name: playlist.name, kind: playlist.kind, createdAt: playlist.createdAt, updatedAt: at(1))
    s.profiles[p] = makeProfile(1, name: "Anna", at: at(2))
    let key = progressKey("m1")
    s.progress[p] = [key: watch(key, 600, at: at(3))]
    var snap = PersonalSnapshot()
    _ = snap.toggleWatchlist(ItemRef(kind: .movie, providerID: "m1"), now: at(4))
    snap.setRating(.up, for: ItemRef(kind: .series, providerID: "s1"), now: at(5))
    _ = snap.toggleFavorite("grupp-1", now: at(6))
    snap.recentChannels = ["lokal"]
    s.personal[p] = snap
    var settings = PlaybackSettings()
    settings.previewsEnabled = false
    settings.updatedAt = at(7)
    s.settings[p] = settings
    s.subtitleOffsets[SubtitleOffsetKey(profileID: p, playlistID: uuid(100), kind: .movie, providerID: "m1")] =
        SubtitleOffset(offsetMs: -250, updatedAt: at(8))
    return s
}

@Suite struct SyncMapperTests {
    @Test func recordsContainNoSecretsOrURLs() throws {
        let s = richState()
        let records = SyncMapper.records(from: s)
        #expect(records.count == 8)
        let encoder = JSONEncoder()
        for r in records {
            let json = try String(decoding: encoder.encode(r), as: UTF8.self).lowercased()
            let payload = String(decoding: r.payload ?? Data(), as: UTF8.self).lowercased()
            for text in [json, payload, r.id.recordName.lowercased()] {
                #expect(!text.contains("http"))
                #expect(!text.contains("hunter2"))
                #expect(!text.contains("secret"))
                #expect(!text.contains("password"))
                #expect(!text.contains("username"))
                #expect(!text.contains("server"))
            }
        }
        // Spellistposten bär bara namn, typ och skapad-tid (id och updatedAt ligger i posten).
        let pl = try #require(records.first { $0.id.kind == .playlist })
        let obj = try #require(JSONSerialization.jsonObject(with: pl.payload!) as? [String: Any])
        #expect(Set(obj.keys) == ["name", "kind", "createdAt"])
    }

    @Test func recordKeysFollowThePlan() {
        let names = Set(SyncMapper.records(from: richState()).map(\.id.recordName))
        let p = uuid(1).uuidString, pl = uuid(100).uuidString
        #expect(names == [
            "profile/\(p)", "playlist/\(pl)", "progress/\(p)/\(pl)/movie/m1", "watchlist/\(p)/movie/m1",
            "rating/\(p)/series/s1", "channelFavorite/\(p)/grupp-1", "settings/\(p)", "subtitleOffset/\(p)/\(pl)/movie/m1",
        ])
    }

    @Test func keysWithSeparatorsInProviderIDRoundTrip() throws {
        var s = SyncableState(deviceID: "A")
        let p = uuid(1)
        let tricky = ["a/b", "100%", "x%2Fy", "/", "ä ö/å"]
        for (i, id) in tricky.enumerated() {
            let k = progressKey(id, series: i % 2 == 0 ? "ser/ies%1" : nil, kind: i % 2 == 0 ? .series : .movie)
            s.progress[p, default: [:]][k] = watch(k, Double(100 + i), at: at(Double(i)))
        }
        var snap = PersonalSnapshot()
        _ = snap.toggleWatchlist(ItemRef(kind: .movie, providerID: "a/b%"), now: at(1))
        _ = snap.toggleFavorite("g/1%", now: at(2))
        s.personal[p] = snap
        let records = SyncMapper.records(from: s)
        let ids = Set(records.map(\.id))
        #expect(ids.count == records.count)
        var other = SyncableState(deviceID: "B")
        SyncMapper.apply(records, to: &other, now: at(100))
        #expect(other == s)
        #expect(other.progress[p] == s.progress[p])
        #expect(other.liveWatchlist(p) == [ItemRef(kind: .movie, providerID: "a/b%")])
        #expect(other.liveFavorites(p) == ["g/1%"])
    }

    @Test func applyStoresRemoteTimestampsNotNow() throws {
        let src = richState()
        var dst = SyncableState(deviceID: "B")
        let now = at(10_000)
        SyncMapper.apply(SyncMapper.records(from: src), to: &dst, now: now)
        #expect(dst.profiles[uuid(1)]?.updatedAt == at(2))
        #expect(dst.settings[uuid(1)]?.updatedAt == at(7))
        #expect(dst.progress[uuid(1)]?[progressKey("m1")]?.updatedAt == at(3))
        #expect(dst == src)
    }

    @Test func applyDoesNotEchoLocalChanges() async throws {
        let cloud = InMemoryCloud(now: { at(10_000) })
        let a = Device("A", transport: cloud.connect())
        let b = Device("B", transport: cloud.connect())
        a.edit(at(100)) { $0 = richState(device: "A") }
        try await a.push()
        let versionAfterA = cloud.currentVersion

        let cs = try await b.pull(at(200))
        #expect(!cs.isEmpty)
        #expect(cs.dirty.isEmpty)
        #expect(cs.profiles == [uuid(1)])
        #expect(cs.progress == [uuid(1)] && cs.personal == [uuid(1)] && cs.settings == [uuid(1)])
        #expect(cs.playlists == [uuid(100)])
        #expect(b.dirty.isEmpty)
        // Om B ändå skickade allt vore det en no-op för molnet (idempotent): versionen är oförändrad.
        try await b.transport.push(SyncMapper.records(from: b.state))
        #expect(cloud.currentVersion == versionAfterA)
        #expect(b.state == a.state)

        // Att applicera samma poster igen ändrar inget.
        let again = SyncMapper.apply(SyncMapper.records(from: a.state), to: &b.state, now: at(300))
        #expect(again.isEmpty && again.dirty.isEmpty)
    }

    @Test func profileTombstoneRemovesAllChildData() throws {
        var a = richState(device: "A")
        var b = SyncableState(deviceID: "B")
        SyncMapper.apply(SyncMapper.records(from: a), to: &b, now: at(100))
        #expect(b.profiles[uuid(1)] != nil)

        a.deleteProfile(uuid(1), now: at(50))
        let records = SyncMapper.records(from: a)
        // Gravsten på profilen och på alla barnposter.
        let tombstoned = Set(records.filter(\.deleted).map(\.id.recordName))
        let p = uuid(1).uuidString, pl = uuid(100).uuidString
        #expect(tombstoned.isSuperset(of: [
            "profile/\(p)", "progress/\(p)/\(pl)/movie/m1", "watchlist/\(p)/movie/m1", "rating/\(p)/series/s1",
            "channelFavorite/\(p)/grupp-1", "settings/\(p)", "subtitleOffset/\(p)/\(pl)/movie/m1",
        ]))
        #expect(records.filter { $0.id.kind != .playlist }.allSatisfy { $0.deleted })

        let cs = SyncMapper.apply(records, to: &b, now: at(100))
        #expect(cs.removedProfiles == [uuid(1)])
        #expect(b.profiles.isEmpty && b.progress[uuid(1)] == nil && b.personal[uuid(1)] == nil
                && b.settings[uuid(1)] == nil && b.subtitleOffsets.isEmpty)
        #expect(b.deletedProfiles[uuid(1)] != nil)
        #expect(b == a)
    }

    @Test func tombstonedProfileChildrenAreDropped() throws {
        var b = SyncableState(deviceID: "B")
        b.deletedProfiles[uuid(1)] = at(50)
        // Nyare barnposter från en offlineenhet släpps (även med senare tidsstämpel än gravstenen).
        let late = richState(device: "C")
        let children = SyncMapper.records(from: late).filter { $0.id.kind != .playlist && $0.id.kind != .profile }
        let cs = SyncMapper.apply(children, to: &b, now: at(200))
        #expect(cs.droppedOrphans == children.count)
        #expect(b.progress.isEmpty && b.personal.isEmpty && b.settings.isEmpty && b.subtitleOffsets.isEmpty)
        // Och de kommer aldrig tillbaka i utgående poster.
        #expect(SyncMapper.records(from: b).allSatisfy { $0.deleted })
    }

    @Test func offlineDeviceCannotResurrectDeletedProfile() async throws {
        let clock = ManualSyncClock(at(0))
        let cloud = InMemoryCloud(now: { clock.now() })
        let a = Device("A", transport: cloud.connect())
        let b = Device("B", transport: cloud.connect())
        a.edit(at(1)) { $0 = richState(device: "A") }
        try await syncAll([a, b], now: at(10))
        #expect(b.state.profiles[uuid(1)] != nil)

        // A raderar profilen; B är offline och redigerar profilen och dess data med SENARE tidsstämplar.
        a.edit(at(20)) { $0.deleteProfile(uuid(1), now: at(20)) }
        try await a.push()
        b.edit(at(30)) { s in
            s.profiles[uuid(1)]!.name = "Nytt namn"
            s.profiles[uuid(1)]!.updatedAt = at(30)
            let k = progressKey("m1")
            s.progress[uuid(1)]![k] = watch(k, 5000, at: at(30))
            s.settings[uuid(1)]!.updatedAt = at(30)
        }
        // B pushar sina (nyare) poster innan den hunnit hämta gravstenen: molnet vänder till levande.
        try await b.push()
        try await syncAll([a, b], now: at(40))
        try await syncAll([a, b], now: at(40))

        for d in [a, b] {
            #expect(d.state.profiles.isEmpty)
            #expect(d.state.progress[uuid(1)] == nil && d.state.settings[uuid(1)] == nil && d.state.personal[uuid(1)] == nil)
            #expect(d.state.deletedProfiles[uuid(1)] != nil)
        }
        let cloudProfile = try #require(cloud.record(for: SyncMapper.profileID(uuid(1))))
        #expect(cloudProfile.deleted)
        // En ny enhet får inte heller se profilen.
        let c = Device("C", transport: cloud.connect())
        try await c.pull(at(50))
        #expect(c.state.profiles.isEmpty && c.state.progress[uuid(1)] == nil)
    }

    @Test func furthestPositionWinsAcrossDevices() throws {
        let k = progressKey("m1")
        var a = SyncableState(deviceID: "A")
        var b = SyncableState(deviceID: "B")
        a.progress[uuid(1)] = [k: watch(k, 3000, at: at(10))]
        b.progress[uuid(1)] = [k: watch(k, 100, dur: 7200, at: at(20))]   // nyare men kortare
        let ra = SyncMapper.records(from: a), rb = SyncMapper.records(from: b)
        SyncMapper.apply(rb, to: &a, now: at(100))
        SyncMapper.apply(ra, to: &b, now: at(100))
        #expect(a.progress[uuid(1)]?[k]?.position == 3000)
        #expect(a.progress[uuid(1)]?[k]?.updatedAt == at(20))
        #expect(a == b)
    }

    @Test func legacyDistantPastPushesButNeverOverwritesNewerRemote() throws {
        // Äldre data utan tidsstämplar (distantPast) pushas till en tom enhet...
        var legacy = SyncableState(deviceID: "L")
        let p = uuid(1)
        var prof = makeProfile(1, at: .distantPast)
        prof.name = "Gammal"
        legacy.profiles[p] = prof
        legacy.settings[p] = PlaybackSettings()            // updatedAt = distantPast
        var snap = PersonalSnapshot()
        snap.ratingEntries = [RatingEntry(item: ItemRef(kind: .movie, providerID: "m"), rating: .up, updatedAt: .distantPast)]
        legacy.personal[p] = snap
        let legacyRecords = SyncMapper.records(from: legacy)
        #expect(legacyRecords.count == 3)
        var fresh = SyncableState(deviceID: "N")
        SyncMapper.apply(legacyRecords, to: &fresh, now: at(100))
        #expect(fresh.profiles[p]?.name == "Gammal")
        #expect(fresh.profiles[p]?.updatedAt == .distantPast)
        #expect(fresh == legacy)

        // ...men skriver aldrig över nyare fjärrdata.
        var newer = SyncableState(deviceID: "N")
        newer.profiles[p] = { var x = makeProfile(1, at: at(5)); x.name = "Ny"; return x }()
        var st = PlaybackSettings(); st.previewsEnabled = false; st.updatedAt = at(5)
        newer.settings[p] = st
        var s2 = PersonalSnapshot()
        s2.ratingEntries = [RatingEntry(item: ItemRef(kind: .movie, providerID: "m"), rating: .down, updatedAt: at(5))]
        newer.personal[p] = s2
        SyncMapper.apply(legacyRecords, to: &newer, now: at(100))
        #expect(newer.profiles[p]?.name == "Ny")
        #expect(newer.settings[p]?.previewsEnabled == false)
        #expect(newer.ratings(p)[ItemRef(kind: .movie, providerID: "m")] == .down)
        // Och tvärtom: legacy tar emot det nyare.
        SyncMapper.apply(SyncMapper.records(from: newer), to: &legacy, now: at(100))
        #expect(legacy == newer)
    }

    @Test func nonFiniteProgressIsSanitizedBeforeEncoding() throws {
        var s = SyncableState(deviceID: "A")
        let k = progressKey("m1")
        s.progress[uuid(1)] = [k: WatchProgress(key: k, position: .nan, duration: .infinity, watched: false, updatedAt: at(1))]
        let r = try #require(SyncMapper.records(from: s).first)
        let payload = try JSONDecoder().decode(SyncProgressPayload.self, from: try #require(r.payload))
        #expect(payload.position == 0 && payload.duration == nil)
    }

    @Test func playlistTombstoneRemovesMetadataAndItsProfiles() throws {
        var a = richState(device: "A")
        var b = SyncableState(deviceID: "B")
        SyncMapper.apply(SyncMapper.records(from: a), to: &b, now: at(100))
        a.deletePlaylist(uuid(100), now: at(60))
        let cs = SyncMapper.apply(SyncMapper.records(from: a), to: &b, now: at(100))
        #expect(cs.removedPlaylists == [uuid(100)])
        #expect(b.playlists.isEmpty && b.profiles.isEmpty && b.progress.isEmpty)
        #expect(b == a)
        // Levande spellist-post som dyker upp igen återupplivar den inte; gravstenen återbekräftas.
        var late = SyncableState(deviceID: "C")
        late.playlists[uuid(100)] = PlaylistMeta(name: "Zombie", kind: .m3u, createdAt: at(0), updatedAt: at(500))
        let cs2 = SyncMapper.apply(SyncMapper.records(from: late), to: &b, now: at(600))
        #expect(b.playlists.isEmpty)
        #expect(cs2.dirty == [SyncMapper.playlistID(uuid(100))])
    }

    @Test func capacityLimitsConvergeIdentically() async throws {
        let caps = SyncCapacities(progress: 3, watchlist: 3, ratings: 3)
        let cloud = InMemoryCloud(now: { at(100_000) })
        let a = Device("A", transport: cloud.connect(), capacities: caps)
        let b = Device("B", transport: cloud.connect(), capacities: caps)
        let c = Device("C", transport: cloud.connect(), capacities: caps)
        let p = uuid(1)
        a.edit(at(0)) { $0.profiles[p] = makeProfile(1) }
        try await syncAll([a, b, c], now: at(10))
        // A och B lägger till olika poster oberoende av varandra, i blandad ordning.
        for i in 0..<5 {
            let ta = at(100 + Double(i * 2)), tb = at(101 + Double(i * 2))
            a.edit(ta) { s in
                let k = progressKey("a\(i)")
                s.progress[p, default: [:]][k] = watch(k, 100, at: ta)
                _ = s.personal[p, default: PersonalSnapshot()].toggleWatchlist(ItemRef(kind: .movie, providerID: "a\(i)"), now: ta)
                s.personal[p, default: PersonalSnapshot()].setRating(.up, for: ItemRef(kind: .movie, providerID: "a\(i)"), now: ta)
            }
            b.edit(tb) { s in
                let k = progressKey("b\(i)")
                s.progress[p, default: [:]][k] = watch(k, 100, at: tb)
                _ = s.personal[p, default: PersonalSnapshot()].toggleWatchlist(ItemRef(kind: .movie, providerID: "b\(i)"), now: tb)
                s.personal[p, default: PersonalSnapshot()].setRating(.down, for: ItemRef(kind: .movie, providerID: "b\(i)"), now: tb)
            }
        }
        try await syncAll([a, b, c], rounds: 5, now: at(1000))
        #expect(a.state == b.state && b.state == c.state, Comment(rawValue: describeDiff(a.state, c.state)))
        for d in [a, b, c] {
            #expect(d.state.progress[p]?.count == 3)
            #expect(d.state.liveWatchlist(p).count == 3)
            #expect(d.state.ratings(p).count == 3)
        }
        // De behållna är de tre senaste (b4, a4, b3 efter tidsstämpel).
        #expect(Set(c.state.progress[p]!.keys.map(\.providerID)) == ["b4", "a4", "b3"])
    }

    @Test func newDeviceGetsFullStateFromCloud() async throws {
        let cloud = InMemoryCloud(now: { at(100_000) })
        let a = Device("A", transport: cloud.connect())
        a.edit(at(100)) { $0 = richState(device: "A") }
        a.edit(at(200)) { $0.deleteProfile(uuid(1), now: at(200)); $0.profiles[uuid(2)] = makeProfile(2, name: "Bo", at: at(210)) }
        try await a.push()
        let fresh = Device("N", transport: cloud.connect())
        try await fresh.pull(at(300))
        #expect(fresh.state == a.state)
        #expect(fresh.state.profiles.keys.contains(uuid(2)) && fresh.state.profiles[uuid(1)] == nil)
        #expect(fresh.dirty.isEmpty)
    }

    @Test func transportFailureKeepsDirtyRecordsForRetry() async throws {
        let cloud = InMemoryCloud(now: { at(10_000) })
        let a = Device("A", transport: cloud.connect())
        a.edit(at(100)) { $0 = richState(device: "A") }
        let before = a.dirty
        #expect(before.ids.count == 8)

        a.transport.failNextPushes(1)
        await #expect(throws: InMemorySyncError.self) { try await a.push() }
        #expect(a.dirty == before)
        #expect(cloud.currentVersion == 0)

        try await a.push()
        #expect(a.dirty.isEmpty)
        #expect(cloud.allRecords.count == 8)

        // Hämtningsfel flyttar inte läsmarkören: nästa försök får allt.
        let b = Device("B", transport: cloud.connect())
        b.transport.failNextFetches(2)
        await #expect(throws: InMemorySyncError.self) { try await b.pull(at(200)) }
        await #expect(throws: InMemorySyncError.self) { try await b.pull(at(200)) }
        try await b.pull(at(200))
        #expect(b.state == a.state)
    }
}
