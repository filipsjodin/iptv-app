import Core
import Foundation

public struct LibraryItem: Sendable, Identifiable, Hashable {
    /// `"\(kind):\(providerID)"`
    public let id: String
    public let kind: ContentKind
    public let providerID: String
    public let title: String
    public let year: Int?
    public let posterURL: URL?

    public init(kind: ContentKind, providerID: String, title: String, year: Int?, posterURL: URL?) {
        self.id = "\(kind.rawValue):\(providerID)"
        self.kind = kind
        self.providerID = providerID
        self.title = title
        self.year = year
        self.posterURL = posterURL
    }
}

/// Kontouppgifter från leverantören (Xtream). Alla fält är `nil` när inget sparats.
public struct PlaylistAccountInfo: Sendable, Equatable {
    public var maxConnections: Int?
    public var expiresAt: Date?
    public var status: String?

    public init(maxConnections: Int?, expiresAt: Date?, status: String?) {
        self.maxConnections = maxConnections
        self.expiresAt = expiresAt
        self.status = status
    }
}
