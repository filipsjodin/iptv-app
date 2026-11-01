import Foundation

public enum SyncKind: String, Codable, Sendable, CaseIterable {
    case playlist, profile, progress, watchlistItem, rating, playbackSettings, channelFavorite, subtitleOffset
}

public struct SyncRecordID: Hashable, Codable, Sendable {
    public var kind: SyncKind
    /// Stabilt id, t.ex. "<profileUUID>/<itemKey>".
    public var key: String

    public init(kind: SyncKind, key: String) {
        self.kind = kind
        self.key = key
    }
}

/// En synkpost. `payload == nil` och `deleted == true` är en gravsten.
/// Posten får aldrig innehålla hemligheter (lösenord, tokens).
public struct SyncRecord: Equatable, Codable, Sendable {
    public var id: SyncRecordID
    public var payload: Data?
    public var updatedAt: Date
    public var deleted: Bool
    /// Enhets-id, används som deterministisk tie-break.
    public var origin: String

    public init(id: SyncRecordID, payload: Data?, updatedAt: Date, deleted: Bool = false, origin: String) {
        self.id = id
        self.payload = payload
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.origin = origin
    }

    public static func tombstone(id: SyncRecordID, updatedAt: Date, origin: String) -> SyncRecord {
        SyncRecord(id: id, payload: nil, updatedAt: updatedAt, deleted: true, origin: origin)
    }
}

/// Payload för `.progress`. Definieras här så att Sync inte beror på PlaybackCore.
public struct SyncProgressPayload: Codable, Equatable, Sendable {
    public var position: Double
    public var duration: Double?
    public var watched: Bool

    public init(position: Double, duration: Double? = nil, watched: Bool) {
        self.position = position
        self.duration = duration
        self.watched = watched
    }
}
