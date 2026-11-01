import Testing
import Foundation
import Core
import Personal
import PlaybackCore
import Sync
@testable import SyncMapping

/// Seedad simulering: tre enheter gör slumpade lokala ändringar, pushar (ibland med fel) och hämtar i slumpad
/// ordning mot ett delat moln. Efter en slutlig fullständig synk ska alla tre ha identiskt tillstånd.
private func runSimulation(seed: UInt64, capacities: SyncCapacities, steps: Int = 160) async throws {
    var rng = SplitMix64(seed: seed)
    let clock = ManualSyncClock(at(0))
    let cloud = InMemoryCloud(now: { clock.now().addingTimeInterval(86_400 * 30) })
    let devices = ["A", "B", "C"].map { Device($0, transport: cloud.connect(), capacities: capacities) }
    let skew: [TimeInterval] = [0, -3, 2]
    let profilePool = [uuid(1), uuid(2), uuid(3)]
    let playlistPool = [uuid(100), uuid(101)]
    let providerIDs = ["m1", "m/2", "m3%", "m4", "m5", "m6", "m7"]

    func pick<T>(_ a: [T]) -> T { a[Int(rng.next() % UInt64(a.count))] }
    func chance(_ percent: UInt64) -> Bool { rng.next() % 100 < percent }

    for _ in 0..<steps {
        let di = Int(rng.next() % 3)
        let d = devices[di]
        clock.advance(by: 1)
        let now = clock.now().addingTimeInterval(skew[di])
        let existing = d.state.profiles.keys.sorted { $0.uuidString < $1.uuidString }
        switch rng.next() % 16 {
        case 0:
            let pl = pick(playlistPool)
            if d.state.deletedPlaylists[pl] == nil {
                d.edit(now) { $0.playlists[pl] = PlaylistMeta(name: "pl\(rng.next() % 1000)", kind: .m3u, createdAt: at(0), updatedAt: now) }
            }
        case 1:
            let p = pick(profilePool), pl = pick(playlistPool)
            if d.state.profiles[p] == nil, d.state.deletedProfiles[p] == nil, d.state.deletedPlaylists[pl] == nil {
                d.edit(now) { $0.profiles[p] = Profile(id: p, playlistID: pl, name: "P\(rng.next() % 100)", avatar: "x", createdAt: now, updatedAt: now) }
            }
        case 2:
            if !existing.isEmpty {
                let p = pick(existing)
                d.edit(now) { $0.profiles[p]!.name = "N\(rng.next() % 1000)"; $0.profiles[p]!.updatedAt = now }
            }
        case 3:
            if !existing.isEmpty, chance(30) { let p = pick(existing); d.edit(now) { $0.deleteProfile(p, now: now) } }
        case 4:
            if chance(15) { let pl = pick(playlistPool); d.edit(now) { $0.deletePlaylist(pl, now: now) } }
        case 5, 6, 7:
            if !existing.isEmpty {
                let p = pick(existing)
                let k = progressKey(pick(providerIDs), playlist: pick([100, 101]))
                let pos = Double(rng.next() % 7000)
                d.edit(now) { $0.progress[p, default: [:]][k] = watch(k, pos, watched: pos > 6500, at: now) }
            }
        case 8:
            if !existing.isEmpty {
                let p = pick(existing), item = ItemRef(kind: .movie, providerID: pick(providerIDs))
                d.edit(now) { _ = $0.personal[p, default: PersonalSnapshot()].toggleWatchlist(item, now: now) }
            }
        case 9:
            if !existing.isEmpty {
                let p = pick(existing), item = ItemRef(kind: .series, providerID: pick(providerIDs))
                let r: Rating? = pick([.up, .down, nil])
                d.edit(now) { $0.personal[p, default: PersonalSnapshot()].setRating(r, for: item, now: now) }
            }
        case 10:
            if !existing.isEmpty {
                let p = pick(existing), g = pick(["g1", "g/2", "g3"])
                d.edit(now) { _ = $0.personal[p, default: PersonalSnapshot()].toggleFavorite(g, now: now) }
            }
        case 11:
            if !existing.isEmpty {
                let p = pick(existing)
                d.edit(now) {
                    var s = $0.settings[p] ?? PlaybackSettings()
                    s.previewsEnabled.toggle()
                    s.touch(now: now)
                    $0.settings[p] = s
                }
            }
        case 12:
            if !existing.isEmpty {
                let p = pick(existing)
                let key = SubtitleOffsetKey(profileID: p, playlistID: pick(playlistPool), kind: .movie, providerID: pick(providerIDs))
                let ms = Int(rng.next() % 2000) - 1000
                d.edit(now) { $0.subtitleOffsets[key] = SubtitleOffset(offsetMs: ms, updatedAt: now) }
            }
        case 13:
            if chance(30) { d.transport.failNextPushes(1) }
            try? await d.push()
        case 14:
            if chance(30) { d.transport.failNextFetches(1) }
            d.transport.setDeliveryOrder(pick([.arrival, .reversed, .shuffled(seed: rng.next())]))
            _ = try? await d.pull(now)
        default:
            // Hel runda: pull sedan push
            _ = try? await d.pull(now)
            try? await d.push()
        }
    }

    // Slutlig fullständig synk utan fel.
    let end = clock.now().addingTimeInterval(10)
    for d in devices { d.transport.setDeliveryOrder(.arrival); d.transport.failNextPushes(0); d.transport.failNextFetches(0) }
    try await syncAll(devices, rounds: 6, now: end)
    let a = devices[0], b = devices[1], c = devices[2]
    #expect(a.state == b.state, Comment(rawValue: "seed \(seed) A!=B\n" + describeDiff(a.state, b.state)))
    let cloudDump = cloud.allRecords.filter { $0.id.kind == .progress }.map { r in
        "\(r.id.key.suffix(12)) \(r.updatedAt.timeIntervalSince1970 - 1_700_000_000) \(r.origin) \(r.deleted) \(String(decoding: r.payload ?? Data(), as: UTF8.self))"
    }.sorted().joined(separator: "\n")
    #expect(b.state == c.state, Comment(rawValue: "seed \(seed) B!=C\n" + describeDiff(b.state, c.state) + "\nCLOUD:\n" + cloudDump))
    for d in devices { #expect(d.dirty.isEmpty, Comment(rawValue: "seed \(seed) \(d.state.deviceID) dirty kvar")) }
    // Raderade profiler har ingen data kvar och inga levande barnposter i molnet påverkar dem.
    for d in devices {
        for p in d.state.deletedProfiles.keys {
            #expect(d.state.profiles[p] == nil && d.state.progress[p] == nil && d.state.personal[p] == nil
                    && d.state.settings[p] == nil, Comment(rawValue: "seed \(seed) zombie-data"))
        }
    }
}

@Suite struct TwoDeviceConvergenceTests {
    @Test(arguments: [UInt64](1...60))
    func twoDevicesConvergeAfterArbitraryInterleaving(seed: UInt64) async throws {
        try await runSimulation(seed: seed, capacities: SyncCapacities())
    }

    @Test(arguments: [UInt64](1001...1060))
    func devicesConvergeWithTinyCapacities(seed: UInt64) async throws {
        try await runSimulation(seed: seed, capacities: SyncCapacities(progress: 3, watchlist: 2, ratings: 2))
    }
}
