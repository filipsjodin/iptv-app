import Foundation
import Core
import Personal
import PlaybackCore
import Sync
@testable import SyncMapping

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

func uuid(_ n: UInt8) -> UUID { UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)) }

func makeProfile(_ n: UInt8, playlist: UInt8 = 100, name: String = "Profil", at date: Date = t0) -> Profile {
    Profile(id: uuid(n), playlistID: uuid(playlist), name: name, avatar: "person", createdAt: date, updatedAt: date)
}

func progressKey(_ id: String, playlist: UInt8 = 100, series: String? = nil, kind: ContentKind = .movie) -> ProgressKey {
    ProgressKey(playlistID: uuid(playlist), kind: kind, providerID: id, seriesProviderID: series)
}

func watch(_ key: ProgressKey, _ pos: Double, dur: Double? = 7200, watched: Bool = false, at date: Date) -> WatchProgress {
    WatchProgress(key: key, position: pos, duration: dur, watched: watched, updatedAt: date)
}

/// En simulerad enhet: tillstånd, dirty-mängd och egen transporthandtag mot det delade molnet.
final class Device {
    var state: SyncableState
    var dirty = SyncDirtySet()
    let transport: InMemorySyncTransport

    init(_ id: String, transport: InMemorySyncTransport, capacities: SyncCapacities = SyncCapacities()) {
        state = SyncableState(deviceID: id, capacities: capacities)
        self.transport = transport
    }

    /// Lokal ändring: muterar, tillämpar kapacitet och markerar ändrade poster som smutsiga.
    func edit(_ now: Date, _ change: (inout SyncableState) -> Void) {
        let old = state
        change(&state)
        for p in Set(state.progress.keys).union(state.personal.keys) {
            SyncMapper.normalize(&state, profile: p, now: now)
        }
        dirty.markChanges(from: old, to: state)
    }

    func push() async throws { try await dirty.push(from: state, via: transport) }

    @discardableResult
    func pull(_ now: Date) async throws -> SyncChangeSet {
        let records = try await transport.fetchChanges()
        let cs = SyncMapper.apply(records, to: &state, now: now)
        dirty.mark(cs.dirty)
        return cs
    }
}

func syncAll(_ devices: [Device], rounds: Int = 4, now: Date) async throws {
    for _ in 0..<rounds {
        for d in devices { try await d.push(); try await d.pull(now) }
    }
}

func describeDiff(_ a: SyncableState, _ b: SyncableState) -> String {
    let ra = Dictionary(SyncMapper.canonical(a).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    let rb = Dictionary(SyncMapper.canonical(b).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    var out: [String] = []
    for id in Set(ra.keys).union(rb.keys).sorted(by: { $0.recordName < $1.recordName }) where ra[id] != rb[id] {
        out.append("\(id.recordName): \(ra[id].map { "\($0.updatedAt.timeIntervalSince1970 - 1_700_000_000) del=\($0.deleted) \(String(decoding: $0.payload ?? Data(), as: UTF8.self))" } ?? "nil") vs \(rb[id].map { "\($0.updatedAt.timeIntervalSince1970 - 1_700_000_000) del=\($0.deleted) \(String(decoding: $0.payload ?? Data(), as: UTF8.self))" } ?? "nil")")
    }
    return out.joined(separator: "\n")
}
