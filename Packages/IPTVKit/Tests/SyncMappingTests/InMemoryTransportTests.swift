import Testing
import Foundation
import Sync
@testable import SyncMapping

private func rec(_ key: String, at s: Double, origin: String = "A", payload: String = "x") -> SyncRecord {
    SyncRecord(id: SyncRecordID(kind: .rating, key: key), payload: Data(payload.utf8), updatedAt: at(s), origin: origin)
}

@Suite struct InMemoryTransportTests {
    @Test func eachDeviceHasItsOwnCursor() async throws {
        let a = InMemorySyncTransport()
        let b = a.another()
        try await a.push([rec("1", at: 1), rec("2", at: 1)])
        #expect(try await b.fetchChanges().count == 2)
        #expect(try await b.fetchChanges().isEmpty)          // redan sedda
        try await a.push([rec("3", at: 1)])
        #expect(try await b.fetchChanges().map(\.id.key) == ["3"])
        // A har sin egen markör och ser allt (även sina egna ändringar), en gång.
        #expect(try await a.fetchChanges().count == 3)
        #expect(try await a.fetchChanges().isEmpty)
    }

    @Test func cloudKeepsOneMergedRecordPerID() async throws {
        let a = InMemorySyncTransport()
        let b = a.another()
        try await a.push([rec("1", at: 5, payload: "ny")])
        try await b.push([rec("1", at: 2, origin: "B", payload: "gammal")])   // äldre vinner inte
        #expect(a.sharedCloud.record(for: SyncRecordID(kind: .rating, key: "1"))?.payload == Data("ny".utf8))
        #expect(a.sharedCloud.allRecords.count == 1)
    }

    @Test func idempotentRepushDoesNotBumpVersion() async throws {
        let a = InMemorySyncTransport()
        try await a.push([rec("1", at: 1)])
        let v = a.sharedCloud.currentVersion
        try await a.push([rec("1", at: 1)])
        #expect(a.sharedCloud.currentVersion == v)
    }

    @Test func faultInjectionFailsExactlyNTimesAndKeepsCursor() async throws {
        let a = InMemorySyncTransport()
        let b = a.another()
        try await a.push([rec("1", at: 1)])
        b.failNextFetches(2)
        for _ in 0..<2 { await #expect(throws: InMemorySyncError.self) { try await b.fetchChanges() } }
        #expect(try await b.fetchChanges().count == 1)
        a.failNextPushes(1)
        await #expect(throws: InMemorySyncError.self) { try await a.push([rec("2", at: 1)]) }
        #expect(a.sharedCloud.allRecords.count == 1)
        try await a.push([rec("2", at: 1)])
        #expect(a.sharedCloud.allRecords.count == 2)
    }

    @Test func deliveryOrderCanBeReversedOrShuffled() async throws {
        let a = InMemorySyncTransport()
        let b = a.another()
        try await a.push((0..<10).map { rec("\($0)", at: 1) })
        b.setDeliveryOrder(.reversed)
        #expect(try await b.fetchChanges().map(\.id.key) == (0..<10).reversed().map(String.init))
        b.resetCursor()
        b.setDeliveryOrder(.shuffled(seed: 7))
        let shuffled = try await b.fetchChanges().map(\.id.key)
        #expect(Set(shuffled) == Set((0..<10).map(String.init)) && shuffled != (0..<10).map(String.init))
    }

    @Test func remoteChangesFiresForOtherDevicesOnly() async throws {
        let a = InMemorySyncTransport()
        let b = a.another()
        var itB = b.remoteChanges.makeAsyncIterator()
        var itA = a.remoteChanges.makeAsyncIterator()
        try await a.push([rec("1", at: 1)])
        #expect(await itB.next() != nil)
        // A:s egen push avisera inte A; B:s push gör det.
        try await b.push([rec("2", at: 1)])
        #expect(await itA.next() != nil)
    }

    @Test func delayedDeliveryStillWorks() async throws {
        let a = InMemorySyncTransport()
        a.setDelay(.milliseconds(5))
        try await a.push([rec("1", at: 1)])
        #expect(try await a.fetchChanges().count == 1)
    }
}
