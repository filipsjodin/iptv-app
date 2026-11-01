#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation
import Sync

/// Ren avbildning `SyncRecord` <-> `CKRecord`. Kräver ingen `CKContainer` (en `CKRecord` kan skapas fristående),
/// så allt här testas utan iCloud-konto.
///
/// Posttyp `SyncRecord` med exakt sex fält: `kind`, `key`, `payload` (Data, utelämnas för gravsten), `updatedAt`,
/// `deleted` (Int 0/1) och `origin`. Inga andra fält skrivs; okända fält vid läsning ignoreras.
///
/// Post-id: CloudKit tillåter högst 255 ASCII-tecken i `recordName`, men synknycklar (`<profil>/<objektnyckel>`)
/// kan vara långa och innehålla godtyckliga tecken. Därför är `recordName` alltid `<kind>-<SHA-256 hex>` av
/// kind + nyckel (deterministiskt, ASCII, 64 + kind-längd + 1 tecken). Själva `kind`/`key` ligger i fälten.
public enum CKRecordCoding {
    public static let recordType = "SyncRecord"
    public static let zoneName = "iptv"
    public static let fieldNames: Set<String> = ["kind", "key", "payload", "updatedAt", "deleted", "origin"]
    /// CloudKit tillåter 1 MB per post; payloads är små. Allt över gränsen synkas inte.
    public static let maxPayloadBytes = 900_000

    public enum CodingError: Error, Equatable, Sendable {
        case payloadTooLarge(bytes: Int)
    }

    public static func defaultZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func recordName(for id: SyncRecordID) -> String {
        let digest = SHA256.hash(data: Data("\(id.kind.rawValue)\n\(id.key)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(id.kind.rawValue)-\(hex)"
    }

    public static func recordID(for id: SyncRecordID, zoneID: CKRecordZone.ID = defaultZoneID()) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: id), zoneID: zoneID)
    }

    /// CloudKit lagrar datum med millisekunders precision; avrunda i förväg så att jämförelser stämmer.
    public static func quantized(_ record: SyncRecord) -> SyncRecord {
        var copy = record
        copy.updatedAt = Date(timeIntervalSince1970: (record.updatedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        return copy
    }

    /// Skriver fälten till `existing` (en kopia av serverns post, så att ändringsmärket följer med) eller till en ny post.
    public static func encode(_ record: SyncRecord, zoneID: CKRecordZone.ID = defaultZoneID(),
                              into existing: CKRecord? = nil) throws -> CKRecord {
        if let payload = record.payload, payload.count > maxPayloadBytes {
            throw CodingError.payloadTooLarge(bytes: payload.count)
        }
        let target = existing ?? CKRecord(recordType: recordType, recordID: recordID(for: record.id, zoneID: zoneID))
        let flag: Int = record.deleted ? 1 : 0
        target["kind"] = record.id.kind.rawValue
        target["key"] = record.id.key
        if let payload = record.payload {
            target["payload"] = payload
        } else {
            target["payload"] = nil
        }
        target["updatedAt"] = quantized(record).updatedAt
        target["deleted"] = flag
        target["origin"] = record.origin
        return target
    }

    /// `nil` när en obligatorisk uppgift saknas eller är av fel typ, eller `kind` är okänd (nyare appversion).
    /// Kraschar aldrig.
    public static func decode(_ record: CKRecord) -> SyncRecord? {
        guard record.recordType == recordType,
              let kindRaw = record["kind"] as? String, let kind = SyncKind(rawValue: kindRaw),
              let key = record["key"] as? String,
              let updatedAt = record["updatedAt"] as? Date,
              let deleted = record["deleted"] as? Int,
              let origin = record["origin"] as? String
        else { return nil }
        return SyncRecord(id: SyncRecordID(kind: kind, key: key), payload: record["payload"] as? Data,
                          updatedAt: updatedAt, deleted: deleted != 0, origin: origin)
    }
}
#endif
