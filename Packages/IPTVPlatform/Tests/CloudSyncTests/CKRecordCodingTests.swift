#if canImport(CloudKit)
import CloudKit
import Foundation
import Sync
import Testing

@testable import CloudSync

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func sample(_ kind: SyncKind, key: String = "p1/x", payload: Data? = Data("{\"a\":1}".utf8),
                    at: Date = t0, deleted: Bool = false, origin: String = "dev1") -> SyncRecord {
    SyncRecord(id: SyncRecordID(kind: kind, key: key), payload: payload, updatedAt: at, deleted: deleted, origin: origin)
}

@Test func ckRecordCodingRoundTripsAllKinds() throws {
    #expect(SyncKind.allCases.count == 8)
    for kind in SyncKind.allCases {
        let live = sample(kind)
        let tomb = SyncRecord.tombstone(id: live.id, updatedAt: t0.addingTimeInterval(5), origin: "dev2")
        for record in [live, tomb] {
            let encoded = try CKRecordCoding.encode(record)
            #expect(encoded.recordType == "SyncRecord")
            #expect(CKRecordCoding.decode(encoded) == record)
        }
    }
}

@Test func tombstoneHasNoPayloadField() throws {
    let tomb = SyncRecord.tombstone(id: SyncRecordID(kind: .rating, key: "k"), updatedAt: t0, origin: "d")
    let encoded = try CKRecordCoding.encode(tomb)
    #expect(encoded["payload"] == nil)
    #expect((encoded["deleted"] as? Int) == 1)
}

@Test func unknownFieldsAreIgnored() throws {
    let record = sample(.watchlistItem)
    let encoded = try CKRecordCoding.encode(record)
    encoded["futureField"] = "något nytt"
    encoded["anotherNumber"] = 42
    #expect(CKRecordCoding.decode(encoded) == record)
}

@Test func missingRequiredFieldsAreSkipped() throws {
    for field in ["kind", "key", "updatedAt", "deleted", "origin"] {
        let encoded = try CKRecordCoding.encode(sample(.profile))
        encoded[field] = nil
        #expect(CKRecordCoding.decode(encoded) == nil, "saknat fält \(field)")
    }
    let unknownKind = try CKRecordCoding.encode(sample(.profile))
    unknownKind["kind"] = "fromTheFuture"
    #expect(CKRecordCoding.decode(unknownKind) == nil)

    let wrongType = try CKRecordCoding.encode(sample(.profile))
    wrongType["updatedAt"] = "inte ett datum"
    #expect(CKRecordCoding.decode(wrongType) == nil)

    let foreign = CKRecord(recordType: "Other", recordID: CKRecord.ID(recordName: "x", zoneID: CKRecordCoding.defaultZoneID()))
    #expect(CKRecordCoding.decode(foreign) == nil)
}

@Test func payloadNeverContainsSecretsFieldNames() throws {
    let encoded = try CKRecordCoding.encode(sample(.playlist))
    #expect(Set(encoded.allKeys()) == CKRecordCoding.fieldNames)
    #expect(CKRecordCoding.fieldNames.count == 6)
    let tomb = try CKRecordCoding.encode(.tombstone(id: SyncRecordID(kind: .playlist, key: "k"), updatedAt: t0, origin: "d"))
    #expect(Set(tomb.allKeys()).isSubset(of: CKRecordCoding.fieldNames))
}

@Test func recordIDStableFromKindAndKey() {
    let a = SyncRecordID(kind: .progress, key: "p/ep1")
    #expect(CKRecordCoding.recordName(for: a) == CKRecordCoding.recordName(for: SyncRecordID(kind: .progress, key: "p/ep1")))
    #expect(CKRecordCoding.recordName(for: a) != CKRecordCoding.recordName(for: SyncRecordID(kind: .rating, key: "p/ep1")))
    #expect(CKRecordCoding.recordName(for: a) != CKRecordCoding.recordName(for: SyncRecordID(kind: .progress, key: "p/ep2")))

    let odd = [String(repeating: "å", count: 5000), "a/b\\c:d é🎬\n", "", "_leading", String(repeating: "x", count: 300)]
    for key in odd {
        for kind in SyncKind.allCases {
            let name = CKRecordCoding.recordName(for: SyncRecordID(kind: kind, key: key))
            #expect(name.count <= 255)
            #expect(name.allSatisfy { $0.isASCII })
            #expect(!name.hasPrefix("_"))
        }
    }
    let id = CKRecordCoding.recordID(for: a)
    #expect(id.zoneID.zoneName == "iptv")
    #expect(id.recordName == CKRecordCoding.recordName(for: a))
}

@Test func oversizedPayloadRejected() throws {
    let big = Data(count: CKRecordCoding.maxPayloadBytes + 1)
    #expect(throws: CKRecordCoding.CodingError.payloadTooLarge(bytes: big.count)) {
        try CKRecordCoding.encode(sample(.playlist, payload: big))
    }
    let atLimit = Data(count: CKRecordCoding.maxPayloadBytes)
    #expect((try CKRecordCoding.encode(sample(.playlist, payload: atLimit))["payload"] as? Data)?.count == atLimit.count)
}

@Test func ckErrorMappingCoversQuotaOfflineNoAccount() {
    #expect(CloudKitFailureMapping.failure(for: CKError(.quotaExceeded)) == .quota)
    #expect(CloudKitFailureMapping.failure(for: CKError(.networkUnavailable)) == .offline)
    #expect(CloudKitFailureMapping.failure(for: CKError(.networkFailure)) == .offline)
    #expect(CloudKitFailureMapping.failure(for: CKError(.notAuthenticated)) == .noAccount)
    #expect(CloudKitFailureMapping.failure(for: CKError(.internalError)) == nil)
    #expect(CloudKitFailureMapping.failure(for: URLError(.badURL)) == nil)
    #expect(CloudKitFailureMapping.failure(forAccountStatus: .available) == nil)
    #expect(CloudKitFailureMapping.failure(forAccountStatus: .noAccount) == .noAccount)
    #expect(CloudKitFailureMapping.failure(forAccountStatus: .restricted) == .noAccount)
    #expect(CloudKitFailureMapping.failure(forAccountStatus: .temporarilyUnavailable) == .offline)
}

@Test func serverRecordChangedProducesMergedRecord() throws {
    let id = SyncRecordID(kind: .playbackSettings, key: "p1")
    let now = t0.addingTimeInterval(1000)
    let older = sample(.playbackSettings, key: "p1", payload: Data("old".utf8), at: t0, origin: "a")
    let newer = sample(.playbackSettings, key: "p1", payload: Data("new".utf8), at: t0.addingTimeInterval(10), origin: "b")
    #expect(older.id == id)

    // Servern har den nyare: vår förlorar, inget skickas om, serverns version levereras.
    let serverWins = CloudConflictResolver.resolve(server: newer, ours: older, now: now)
    #expect(serverWins.merged == newer)
    #expect(!serverWins.needsResend)

    // Vår är nyare: den skickas om.
    let oursWins = CloudConflictResolver.resolve(server: older, ours: newer, now: now)
    #expect(oursWins.merged == newer)
    #expect(oursWins.needsResend)

    // Ingen egen väntande post: ta serverns.
    let none = CloudConflictResolver.resolve(server: newer, ours: nil, now: now)
    #expect(none.merged == newer && !none.needsResend)

    // Progress slås ihop (max/OR) till något som varken är serverns eller vår: skickas om.
    let pid = SyncRecordID(kind: .progress, key: "p1/ep")
    let server = SyncRecord(id: pid, payload: SyncProgressPayload(position: 100, duration: 500, watched: false).encoded(),
                            updatedAt: t0.addingTimeInterval(20), origin: "a")
    let ours = SyncRecord(id: pid, payload: SyncProgressPayload(position: 300, duration: nil, watched: true).encoded(),
                          updatedAt: t0.addingTimeInterval(10), origin: "b")
    let merged = CloudConflictResolver.resolve(server: server, ours: ours, now: now)
    #expect(merged.needsResend)
    let payload = try JSONDecoder().decode(SyncProgressPayload.self, from: #require(merged.merged.payload))
    #expect(payload.position == 300 && payload.watched && payload.duration == 500)
}

@Test func accountChangeNeverDeletesLocalData() {
    for kind in AccountChangeKind.allCases {
        #expect(!AccountChangeAction.action(for: kind).deletesLocalData)
    }
    for action in AccountChangeAction.allCases { #expect(!action.deletesLocalData) }
    #expect(AccountChangeAction.action(for: .signOut) == .suspendNoAccount)
    #expect(AccountChangeAction.action(for: .signIn) == .keepRunning)
    #expect(AccountChangeAction.action(for: .switchAccounts) == .resetEngineStateAndSuspend)
}

@Test func containerIdentifierFallsBackToDefault() {
    #expect(CloudKitConfiguration.containerIdentifier(infoValue: nil) == "iCloud.se.sjodin.iptv")
    #expect(CloudKitConfiguration.containerIdentifier(infoValue: "") == "iCloud.se.sjodin.iptv")
    #expect(CloudKitConfiguration.containerIdentifier(infoValue: "$(CLOUDKIT_CONTAINER)") == "iCloud.se.sjodin.iptv")
    #expect(CloudKitConfiguration.containerIdentifier(infoValue: " iCloud.x.y ") == "iCloud.x.y")
}
#endif
