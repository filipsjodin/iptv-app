import Foundation
import Core

/// Normaliserad metadata för en film eller serie (från TMDB, kompletterad med OMDb-betyg).
public struct TitleMetadata: Codable, Sendable, Equatable {
    public var tmdbID: Int
    public var kind: ContentKind
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var year: Int?
    public var runtimeMinutes: Int?
    public var genres: [Genre]
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    /// TMDB-bildsökvägar (t.ex. "/abc.jpg"); bygg URL med `TMDBImage.url(path:size:)`.
    public var posterPath: String?
    public var backdropPath: String?
    public var logoPath: String?
    /// Högst 15 personer, i TMDB:s ordning.
    public var cast: [Person]
    public var directors: [Person]
    public var creators: [Person]
    public var keywords: [String]
    public var certification: String?
    public var ageLimit: Int?
    public var recommendations: [Int]
    public var similar: [Int]
    public var imdbID: String?
    public var seasons: [SeasonSummary]
    /// Språket metadatan hämtades på (t.ex. "sv-SE").
    public var language: String
    /// Fylls i senare av MetadataService via OMDb.
    public var imdbRating: Double?
    public var rottenTomatoes: Int?

    public init(tmdbID: Int, kind: ContentKind, title: String, originalTitle: String? = nil, overview: String? = nil,
                year: Int? = nil, runtimeMinutes: Int? = nil, genres: [Genre] = [], voteAverage: Double? = nil,
                voteCount: Int? = nil, popularity: Double? = nil, posterPath: String? = nil, backdropPath: String? = nil,
                logoPath: String? = nil, cast: [Person] = [], directors: [Person] = [], creators: [Person] = [],
                keywords: [String] = [], certification: String? = nil, ageLimit: Int? = nil, recommendations: [Int] = [],
                similar: [Int] = [], imdbID: String? = nil, seasons: [SeasonSummary] = [], language: String,
                imdbRating: Double? = nil, rottenTomatoes: Int? = nil) {
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.year = year
        self.runtimeMinutes = runtimeMinutes
        self.genres = genres
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.popularity = popularity
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.logoPath = logoPath
        self.cast = cast
        self.directors = directors
        self.creators = creators
        self.keywords = keywords
        self.certification = certification
        self.ageLimit = ageLimit
        self.recommendations = recommendations
        self.similar = similar
        self.imdbID = imdbID
        self.seasons = seasons
        self.language = language
        self.imdbRating = imdbRating
        self.rottenTomatoes = rottenTomatoes
    }
}

public struct Genre: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Person: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public init(id: Int, name: String, character: String? = nil, profilePath: String? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profilePath = profilePath
    }
}

public struct SeasonSummary: Codable, Hashable, Sendable {
    public var number: Int
    public var episodeCount: Int
    public var name: String?
    public init(number: Int, episodeCount: Int, name: String? = nil) {
        self.number = number
        self.episodeCount = episodeCount
        self.name = name
    }
}

public struct TMDBSearchResult: Codable, Sendable, Hashable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var popularity: Double
    public var kind: ContentKind
    public init(id: Int, title: String, originalTitle: String?, year: Int?, popularity: Double, kind: ContentKind) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.popularity = popularity
        self.kind = kind
    }
}

public enum TrendingWindow: String, Sendable, Codable, Hashable {
    case day, week
}

/// Bygger bild-URL:er ur TMDB-sökvägar.
public enum TMDBImage {
    public enum Size: String, Sendable, CaseIterable {
        case w342, w780, w1280, original
    }

    public static let baseURL = "https://image.tmdb.org/t/p/"

    public static func url(path: String, size: Size) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        // Bas-URL:en är konstant och sökvägen procentkodad, så URL:en är alltid giltig.
        return URL(string: baseURL + size.rawValue + "/" + encoded)!
    }
}

/// Externa betyg från OMDb.
public struct ExternalRatings: Codable, Sendable, Equatable {
    public var imdb: Double?
    public var rottenTomatoes: Int?
    public init(imdb: Double?, rottenTomatoes: Int?) {
        self.imdb = imdb
        self.rottenTomatoes = rottenTomatoes
    }
}
