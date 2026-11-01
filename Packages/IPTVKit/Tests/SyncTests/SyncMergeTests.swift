import Testing
import Foundation
@testable import Sync

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private func t(_ s: Double) -> Date { now.addingTimeInterval(s) }
private let rid = SyncRecordID(kind: .rating, key: "p/item")
private let pid = SyncRecordID(kind: .progress, key: "p/item")

private func rec(_ payload: String?, at: Double, origin: String = "A", deleted: Bool = false, id: SyncRecordID = rid) -> SyncRecord {
    SyncRecord(id: id, payload: payload.map { Data($0.utf8) }, updatedAt: t(at), deleted: deleted, origin: origin)
}
private func prog(_ pos: Double, dur: Double? = nil, watched: Bool = false, at: Double, origin: String = "A") -> SyncRecord {
    let data = SyncProgressPayload(position: pos, duration: dur, watched: watched).encoded()
    return SyncRecord(id: pid, payload: data, updatedAt: t(at), deleted: false, origin: origin)
}
private func decode(_ r: SyncRecord) -> SyncProgressPayload {
    try! JSONDecoder().decode(SyncProgressPayload.self, from: r.payload!)
}
private func m(_ a: SyncRecord?, _ b: SyncRecord) -> SyncRecord { SyncMerge.merge(local: a, remote: b, now: now) }

private func permutations<T>(_ a: [T]) -> [[T]] {
    if a.count <= 1 { return [a] }
    var out: [[T]] = []
    for i in a.indices {
        var rest = a
        let x = rest.remove(at: i)
        out += permutations(rest).map { [x] + $0 }
    }
    return out
}

@Suite struct SyncMergeTests {
    @Test func latestWriteWinsPerRecord() {
        #expect(m(rec("old", at: 1), rec("new", at: 2)).payload == Data("new".utf8))
        #expect(m(rec("new", at: 2), rec("old", at: 1)).payload == Data("new".utf8))
        #expect(m(nil, rec("x", at: 1)).payload == Data("x".utf8))
    }

    @Test func tieBreaksOnOriginDeterministically() {
        let a = rec("fromA", at: 5, origin: "A"), b = rec("fromB", at: 5, origin: "B")
        #expect(m(a, b) == a)
        #expect(m(b, a) == a)
    }

    @Test func tombstoneBeatsOlderUpdate() {
        let tomb = SyncRecord.tombstone(id: rid, updatedAt: t(10), origin: "A")
        #expect(m(rec("x", at: 5), tomb).deleted)
        #expect(m(tomb, rec("x", at: 5)).deleted)
        // lika tid: ordningen avgör, men resultatet är symmetriskt
        let live = rec(nil, at: 10, origin: "A")
        #expect(m(live, tomb) == m(tomb, live))
    }

    @Test func laterRecreationBeatsTombstone() {
        let tomb = SyncRecord.tombstone(id: rid, updatedAt: t(10), origin: "A")
        let again = rec("back", at: 11)
        #expect(m(tomb, again) == again)
        #expect(m(again, tomb) == again)
    }

    @Test func futureTimestampIsClamped() {
        let future = rec("evil", at: 10 * 86_400)
        let r = m(rec("local", at: 100), future)
        #expect(r.updatedAt == now.addingTimeInterval(86_400))
        let later = rec("fix", at: 86_400 + 5)
        #expect(SyncMerge.merge(local: r, remote: later, now: now.addingTimeInterval(10)).payload == Data("fix".utf8))
    }

    @Test func progressKeepsFurthestPositionAndWatchedFlag() {
        let a = prog(100, dur: 1000, watched: true, at: 1, origin: "A")
        let b = prog(50, dur: 2000, watched: false, at: 2, origin: "B")
        for r in [m(a, b), m(b, a)] {
            let p = decode(r)
            #expect(p.position == 100)
            #expect(p.watched)
            #expect(p.duration == 2000)
            #expect(r.updatedAt == t(2))
            #expect(r.origin == "B")
        }
        let c = prog(10, dur: nil, at: 3)
        #expect(decode(m(a, c)).duration == 1000)
    }

    @Test func mergeIsCommutativeAssociativeIdempotent() {
        let recs: [SyncRecord] = [
            rec("a", at: 1, origin: "A"),
            rec("b", at: 5, origin: "B"),
            rec("c", at: 5, origin: "C"),
            SyncRecord.tombstone(id: rid, updatedAt: t(3), origin: "D"),
        ]
        let progs: [SyncRecord] = [
            prog(10, dur: 100, at: 1, origin: "A"),
            prog(70, dur: 200, watched: true, at: 5, origin: "B"),
            prog(30, dur: nil, at: 5, origin: "C"),
            prog(40, dur: 300, at: 5, origin: "C"),
        ]
        let durTriple: [SyncRecord] = [
            prog(10, dur: nil, at: 5, origin: "A"),
            prog(20, dur: 100, at: 3, origin: "A"),
            prog(30, dur: 50, at: 5, origin: "A"),
            prog(5, dur: 70, at: 4, origin: "B"),
        ]
        let clampedSet: [SyncRecord] = [
            rec("a", at: 10 * 86_400, origin: "A"),
            rec("b", at: 20 * 86_400, origin: "B"),
            rec("c", at: 86_400, origin: "C"),
            rec("d", at: 86_400 + 1, origin: "A"),
        ]
        let nilVsPayload: [SyncRecord] = [
            rec(nil, at: 5, origin: "A"),
            rec("x", at: 5, origin: "A"),
            rec("y", at: 5, origin: "A"),
            rec(nil, at: 5, origin: "A", deleted: true),
        ]
        for set in [recs, progs, durTriple, clampedSet, nilVsPayload] {
            let results = permutations(set).map { $0.dropFirst().reduce($0[0]) { m($0, $1) } }
            #expect(results.allSatisfy { $0 == results[0] })
            let g1 = m(m(set[0], set[1]), m(set[2], set[3]))
            let g2 = m(set[0], m(set[1], m(set[2], set[3])))
            let g3 = m(m(m(set[0], set[1]), set[2]), set[3])
            #expect(g1 == results[0] && g2 == results[0] && g3 == results[0])
            #expect(m(results[0], results[0]) == results[0])
            for r in set { #expect(m(results[0], r) == results[0]) }
        }
    }

    @Test func payloadOfLoserIsNotMixedIn() {
        let r = m(rec("loser", at: 1), rec("winner", at: 2))
        #expect(r.payload == Data("winner".utf8))
        let tomb = SyncRecord.tombstone(id: rid, updatedAt: t(9), origin: "A")
        #expect(m(rec("loser", at: 1), tomb).payload == nil)
    }

    @Test func liveRecordWithNilPayloadIsKept() {
        let r = m(rec(nil, at: 2), rec("x", at: 1))
        #expect(r.payload == nil && !r.deleted)
    }

    @Test func equalTimestampAndOriginUsesPayloadBytes() {
        let a = rec("aaa", at: 1), b = rec("bbb", at: 1)
        #expect(m(a, b) == a)
        #expect(m(b, a) == a)
    }

    @Test func progressDecodeFailureFallsBackToLWW() {
        let bad = SyncRecord(id: pid, payload: Data("nope".utf8), updatedAt: t(5), deleted: false, origin: "A")
        let good = prog(99, at: 1)
        #expect(m(good, bad) == bad)
        #expect(m(bad, good) == bad)
    }

    @Test func progressTombstoneFollowsLWW() {
        let tomb = SyncRecord.tombstone(id: pid, updatedAt: t(9), origin: "A")
        #expect(m(prog(99, at: 1), tomb).deleted)
        let again = prog(5, at: 10)
        #expect(decode(m(tomb, again)).position == 5)
    }

    @Test func progressMergeIsByteIdempotent() {
        let canonical = prog(10, dur: 5, at: 1)
        #expect(m(canonical, canonical) == canonical)
        #expect(m(nil, canonical) == canonical)
        let raw = Data(#"{"watched":false,"position":3,"duration":9}"#.utf8)
        let hand = SyncRecord(id: pid, payload: raw, updatedAt: t(1), deleted: false, origin: "A")
        #expect(m(hand, hand) == hand)
        #expect(m(nil, hand) == hand)
        #expect(m(hand, canonicalOf(hand)) == m(canonicalOf(hand), hand))
    }

    @Test func liveProgressWithNilPayloadFallsBackToLWW() {
        let nilP = SyncRecord(id: pid, payload: nil, updatedAt: t(5), deleted: false, origin: "A")
        #expect(m(prog(9, at: 1), nilP) == nilP)
        #expect(m(nilP, prog(9, at: 1)) == nilP)
    }

    @Test func durationIsMaxOfNonNil() {
        let a = prog(1, dur: nil, at: 5), b = prog(1, dur: 100, at: 3), c = prog(1, dur: 50, at: 5)
        #expect(decode(m(m(a, b), c)).duration == 100)
        #expect(decode(m(a, m(b, c))).duration == 100)
    }
}

private func canonicalOf(_ r: SyncRecord) -> SyncRecord {
    var c = r
    c.payload = (try! JSONDecoder().decode(SyncProgressPayload.self, from: r.payload!)).encoded()
    return c
}
