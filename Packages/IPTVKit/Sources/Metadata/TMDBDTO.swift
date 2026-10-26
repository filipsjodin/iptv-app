import Foundation
import Core

// Avkodningsmodeller för TMDB v3. Allt utom `id` är valfritt så att glesa svar inte fäller hela anropet.

struct TMDBPage<Item: Decodable>: Decodable {
    let results: [Item]?
}

struct TMDBIDOnly: Decodable {
    let id: Int
}

struct TMDBSearchItemDTO: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let releaseDate: String?
    let firstAirDate: String?
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, popularity
        case originalTitle = "original_title"
        case originalName = "original_name"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    func result(kind: ContentKind) -> TMDBSearchResult? {
        guard let display = nonEmpty(title) ?? nonEmpty(name) else { return nil }
        return TMDBSearchResult(id: id, title: display, originalTitle: nonEmpty(originalTitle) ?? nonEmpty(originalName),
                                year: tmdbYear(releaseDate ?? firstAirDate), popularity: popularity ?? 0, kind: kind)
    }
}

struct TMDBPersonDTO: Decodable {
    let id: Int
    let name: String?
    let character: String?
    let job: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character, job
        case profilePath = "profile_path"
    }

    func person(includeCharacter: Bool) -> Person? {
        guard let name = nonEmpty(name) else { return nil }
        return Person(id: id, name: name, character: includeCharacter ? nonEmpty(character) : nil, profilePath: nonEmpty(profilePath))
    }
}

struct TMDBNamedDTO: Decodable {
    let id: Int
    let name: String?
}

struct TMDBDetailsDTO: Decodable {
    let id: Int
    // Film
    let title: String?
    let originalTitle: String?
    let releaseDate: String?
    let runtime: Int?
    let imdbID: String?
    let releaseDates: ReleaseDates?
    // Serie
    let name: String?
    let originalName: String?
    let firstAirDate: String?
    let episodeRunTime: [Int]?
    let createdBy: [TMDBPersonDTO]?
    let seasons: [Season]?
    let contentRatings: ContentRatings?
    // Gemensamt
    let overview: String?
    let genres: [TMDBNamedDTO]?
    let voteAverage: Double?
    let voteCount: Int?
    let popularity: Double?
    let posterPath: String?
    let backdropPath: String?
    let credits: Credits?
    let keywords: Keywords?
    let recommendations: TMDBPage<TMDBIDOnly>?
    let similar: TMDBPage<TMDBIDOnly>?
    let images: Images?
    let externalIDs: ExternalIDs?

    enum CodingKeys: String, CodingKey {
        case id, title, runtime, name, seasons, overview, genres, popularity, credits, keywords, recommendations, similar, images
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case imdbID = "imdb_id"
        case releaseDates = "release_dates"
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case episodeRunTime = "episode_run_time"
        case createdBy = "created_by"
        case contentRatings = "content_ratings"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case externalIDs = "external_ids"
    }

    struct ReleaseDates: Decodable {
        let results: [Country]?
        struct Country: Decodable {
            let iso: String
            let releaseDates: [Entry]?
            enum CodingKeys: String, CodingKey {
                case iso = "iso_3166_1"
                case releaseDates = "release_dates"
            }
        }
        struct Entry: Decodable {
            let certification: String?
            let type: Int?
        }
    }

    struct ContentRatings: Decodable {
        let results: [Rating]?
        struct Rating: Decodable {
            let iso: String
            let rating: String?
            enum CodingKeys: String, CodingKey {
                case iso = "iso_3166_1"
                case rating
            }
        }
    }

    struct Season: Decodable {
        let seasonNumber: Int?
        let episodeCount: Int?
        let name: String?
        enum CodingKeys: String, CodingKey {
            case name
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
        }
    }

    struct Credits: Decodable {
        let cast: [TMDBPersonDTO]?
        let crew: [TMDBPersonDTO]?
    }

    /// Film: `keywords`, serie: `results`.
    struct Keywords: Decodable {
        let keywords: [TMDBNamedDTO]?
        let results: [TMDBNamedDTO]?
    }

    struct Images: Decodable {
        let logos: [Logo]?
        struct Logo: Decodable {
            let filePath: String?
            let language: String?
            enum CodingKeys: String, CodingKey {
                case filePath = "file_path"
                case language = "iso_639_1"
            }
        }
    }

    struct ExternalIDs: Decodable {
        let imdbID: String?
        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
    }

    static let maxCast = 15
    static let maxRelated = 20
    static let theatricalReleaseType = 3

    func metadata(kind: ContentKind, language: String) throws -> TitleMetadata {
        let isSeries = kind == .series
        guard let displayTitle = nonEmpty(isSeries ? name : title) ?? nonEmpty(isSeries ? title : name) else {
            throw TMDBError.invalidResponse
        }
        let cast = (credits?.cast ?? []).compactMap { $0.person(includeCharacter: true) }.prefix(Self.maxCast)
        let directors = (credits?.crew ?? []).filter { $0.job == "Director" }.compactMap { $0.person(includeCharacter: false) }
        let keywordList = keywords?.keywords ?? keywords?.results ?? []
        let rating = Certification.ageLimit(from: isSeries ? seriesCertifications() : movieCertifications())
        return TitleMetadata(
            tmdbID: id,
            kind: kind,
            title: displayTitle,
            originalTitle: nonEmpty(isSeries ? originalName : originalTitle),
            overview: nonEmpty(overview),
            year: tmdbYear(isSeries ? firstAirDate : releaseDate),
            runtimeMinutes: isSeries ? episodeRunTime?.first(where: { $0 > 0 }) : runtime.flatMap { $0 > 0 ? $0 : nil },
            genres: (genres ?? []).compactMap { g in nonEmpty(g.name).map { Genre(id: g.id, name: $0) } },
            voteAverage: voteAverage,
            voteCount: voteCount,
            popularity: popularity,
            posterPath: nonEmpty(posterPath),
            backdropPath: nonEmpty(backdropPath),
            logoPath: preferredLogo(),
            cast: Array(cast),
            directors: directors,
            creators: isSeries ? (createdBy ?? []).compactMap { $0.person(includeCharacter: false) } : [],
            keywords: keywordList.compactMap { nonEmpty($0.name) },
            certification: rating.certification,
            ageLimit: rating.age,
            recommendations: Array((recommendations?.results?.map(\.id) ?? []).prefix(Self.maxRelated)),
            similar: Array((similar?.results?.map(\.id) ?? []).prefix(Self.maxRelated)),
            imdbID: nonEmpty(externalIDs?.imdbID) ?? nonEmpty(imdbID),
            seasons: isSeries ? seasonSummaries() : [],
            language: language
        )
    }

    /// Per land: biopremiärer först, sedan övriga i TMDB:s ordning.
    private func movieCertifications() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for country in releaseDates?.results ?? [] {
            let entries = country.releaseDates ?? []
            let theatrical = entries.filter { $0.type == Self.theatricalReleaseType }
            let others = entries.filter { $0.type != Self.theatricalReleaseType }
            out[country.iso, default: []] += (theatrical + others).compactMap(\.certification)
        }
        return out
    }

    private func seriesCertifications() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for r in contentRatings?.results ?? [] {
            if let rating = r.rating { out[r.iso, default: []].append(rating) }
        }
        return out
    }

    /// Hoppar över säsong 0 ("Specials").
    private func seasonSummaries() -> [SeasonSummary] {
        (seasons ?? []).compactMap { s in
            guard let number = s.seasonNumber, number > 0 else { return nil }
            return SeasonSummary(number: number, episodeCount: s.episodeCount ?? 0, name: nonEmpty(s.name))
        }
    }

    /// Svensk logga före engelsk före språklös.
    private func preferredLogo() -> String? {
        let logos = (images?.logos ?? []).filter { nonEmpty($0.filePath) != nil }
        for lang in ["sv", "en", nil] as [String?] {
            if let hit = logos.first(where: { nonEmpty($0.language) == lang }) { return hit.filePath }
        }
        return nil
    }
}

/// Minimalt svar för översiktsreserven.
struct TMDBOverviewDTO: Decodable {
    let overview: String?
}

func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// År ur TMDB-datum "YYYY-MM-DD"; tomt eller ogiltigt ger nil.
func tmdbYear(_ date: String?) -> Int? {
    guard let date, date.count >= 4, let y = Int(date.prefix(4)), y > 1800 else { return nil }
    return y
}
