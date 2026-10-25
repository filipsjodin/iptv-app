import Foundation

public enum ContentKind: String, Sendable, Codable, Hashable {
    case movie, series, live
}

public enum PlaylistSourceKind: String, Sendable, Codable, Hashable {
    case xtream, m3u
}

/// Publik metadata om en spellista. Server/URL och inloggning ligger i `PlaylistSecret`.
public struct Playlist: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var kind: PlaylistSourceKind
    public var createdAt: Date
    public var lastImportedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: PlaylistSourceKind, createdAt: Date = Date(), lastImportedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.lastImportedAt = lastImportedAt
    }
}

public struct Category: Sendable, Codable, Hashable {
    public var providerID: String
    public var name: String
    public var kind: ContentKind
    public var sortIndex: Int

    public init(providerID: String, name: String, kind: ContentKind, sortIndex: Int) {
        self.providerID = providerID
        self.name = name
        self.kind = kind
        self.sortIndex = sortIndex
    }
}

public struct Movie: Sendable, Codable, Hashable {
    public var providerID: String
    public var title: String
    public var year: Int?
    public var categoryID: String?
    public var posterURL: URL?
    public var container: String?
    public var tmdbID: Int?
    public var rating: Double?
    public var addedAt: Date?
    public var locator: StreamLocator

    public init(providerID: String, title: String, year: Int? = nil, categoryID: String? = nil, posterURL: URL? = nil,
                container: String? = nil, tmdbID: Int? = nil, rating: Double? = nil, addedAt: Date? = nil,
                locator: StreamLocator) {
        self.providerID = providerID
        self.title = title
        self.year = year
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.container = container
        self.tmdbID = tmdbID
        self.rating = rating
        self.addedAt = addedAt
        self.locator = locator
    }
}

public struct Series: Sendable, Codable, Hashable {
    public var providerID: String
    public var title: String
    public var year: Int?
    public var categoryID: String?
    public var posterURL: URL?
    public var tmdbID: Int?
    public var rating: Double?
    public var addedAt: Date?

    public init(providerID: String, title: String, year: Int? = nil, categoryID: String? = nil, posterURL: URL? = nil,
                tmdbID: Int? = nil, rating: Double? = nil, addedAt: Date? = nil) {
        self.providerID = providerID
        self.title = title
        self.year = year
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.tmdbID = tmdbID
        self.rating = rating
        self.addedAt = addedAt
    }
}

public struct Episode: Sendable, Codable, Hashable {
    public var providerID: String
    public var seriesProviderID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var container: String?
    public var locator: StreamLocator

    public init(providerID: String, seriesProviderID: String, season: Int, number: Int, title: String,
                container: String? = nil, locator: StreamLocator) {
        self.providerID = providerID
        self.seriesProviderID = seriesProviderID
        self.season = season
        self.number = number
        self.title = title
        self.container = container
        self.locator = locator
    }
}

public struct LiveStream: Sendable, Codable, Hashable {
    public var providerID: String
    public var name: String
    public var categoryID: String?
    public var logoURL: URL?
    public var epgChannelID: String?
    public var locator: StreamLocator

    public init(providerID: String, name: String, categoryID: String? = nil, logoURL: URL? = nil,
                epgChannelID: String? = nil, locator: StreamLocator) {
        self.providerID = providerID
        self.name = name
        self.categoryID = categoryID
        self.logoURL = logoURL
        self.epgChannelID = epgChannelID
        self.locator = locator
    }
}
