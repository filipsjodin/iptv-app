import Testing
import Foundation
import Core
import Providers
import ProvidersTestSupport
@testable import Metadata

private let token = "fake-tmdb-read-token-0123456789"

func metadataFixture(_ name: String) throws -> Data {
    let base = (name as NSString).deletingPathExtension
    guard let url = Bundle.module.url(forResource: base, withExtension: "json", subdirectory: "Fixtures") else {
        throw URLError(.fileDoesNotExist)
    }
    return try Data(contentsOf: url)
}

/// Nyckel = sökväg, plus "@en-US" när anropet görs på reservspråket.
@Sendable private func tmdbKey(_ url: URL) -> String {
    let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let lang = c?.queryItems?.first { $0.name == "language" }?.value
    return (c?.path ?? "") + (lang == "en-US" ? "@en-US" : "")
}

private func stub(_ map: [String: String], extra: [String: StubResponse] = [:]) throws -> StubHTTPClient {
    var responses = extra
    for (k, file) in map { responses[k] = StubResponse(body: try metadataFixture(file)) }
    return StubHTTPClient(responses: responses, key: tmdbKey)
}

private func query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

@Test func searchParsesYearsAndKinds() async throws {
    let http = try stub(["/3/search/movie": "tmdb_search_movie.json", "/3/search/tv": "tmdb_search_tv.json"])
    let client = TMDBClient(token: token, http: http)
    let movies = try await client.search("Dune", year: 2024, kind: .movie)
    #expect(movies.map(\.id) == [693134, 438631, 999001])
    #expect(movies[0].year == 2024 && movies[0].title == "Dune: Del två" && movies[0].originalTitle == "Dune: Part Two")
    #expect(movies[0].popularity == 512.3 && movies[0].kind == .movie)
    #expect(movies[1].year == 2021)
    #expect(movies[2].year == nil)
    #expect(query(http.lastURL, "query") == "Dune")
    #expect(query(http.lastURL, "year") == "2024")
    #expect(query(http.lastURL, "language") == "sv-SE")

    let shows = try await client.search("Bron", year: 2011, kind: .series)
    #expect(shows.count == 1 && shows[0].title == "Bron" && shows[0].year == 2011 && shows[0].kind == .series)
    #expect(query(http.lastURL, "first_air_date_year") == "2011")
}

@Test func tokenOnlyInHeaderNeverInURL() async throws {
    let http = try stub(["/3/search/movie": "tmdb_search_movie.json", "/3/movie/693134": "tmdb_movie_details.json"])
    let client = TMDBClient(token: token, http: http)
    _ = try await client.search("Dune", year: nil, kind: .movie)
    _ = try await client.details(id: 693134, kind: .movie)
    #expect(http.requests.count == 2)
    for r in http.requests {
        #expect(!r.url.absoluteString.contains(token))
        #expect(!r.url.absoluteString.contains("api_key"))
        #expect(r.headers["Authorization"] == "Bearer \(token)")
        #expect(r.url.host == "api.themoviedb.org")
    }
    #expect(!String(describing: client).contains(token))
    #expect(!String(reflecting: client).contains(token))
}

@Test func detailsMapsEverything() async throws {
    let http = try stub(["/3/movie/693134": "tmdb_movie_details.json"])
    let m = try await TMDBClient(token: token, http: http).details(id: 693134, kind: .movie)
    #expect(http.requests.count == 1)
    #expect(query(http.lastURL, "append_to_response") == "credits,keywords,recommendations,similar,images,release_dates,external_ids")
    #expect(query(http.lastURL, "include_image_language") == "sv,en,null")
    #expect(m.tmdbID == 693134 && m.kind == .movie)
    #expect(m.title == "Dune: Del två" && m.originalTitle == "Dune: Part Two")
    #expect(m.overview?.hasPrefix("Paul förenar") == true)
    #expect(m.year == 2024 && m.runtimeMinutes == 167)
    #expect(m.genres == [Genre(id: 878, name: "Science fiction"), Genre(id: 12, name: "Äventyr")])
    #expect(m.voteAverage == 8.2 && m.voteCount == 6123 && m.popularity == 512.3)
    #expect(m.posterPath == "/fakePoster693134.jpg" && m.backdropPath == "/fakeBackdrop693134.jpg")
    #expect(m.logoPath == "/fakeLogoSv.png")
    #expect(m.cast.count == 15)
    #expect(m.cast[0] == Person(id: 900100, name: "Anna Berg", character: "Rollfigur 1", profilePath: "/fakeProfile00.jpg"))
    #expect(m.cast[3].profilePath == nil)
    #expect(m.directors == [Person(id: 900500, name: "Dag Regissör", character: nil, profilePath: "/fakeDirector.jpg")])
    #expect(m.creators.isEmpty)
    #expect(m.keywords == ["desert", "prophecy", "revenge"])
    #expect(m.recommendations == [438631, 823464])
    #expect(m.similar == [11000, 11001])
    #expect(m.imdbID == "tt15239678")
    #expect(m.certification == "11" && m.ageLimit == 11)
    #expect(m.seasons.isEmpty)
    #expect(m.language == "sv-SE")
    #expect(m.imdbRating == nil && m.rottenTomatoes == nil)
}

@Test func seriesDetailsUseTvEndpoint() async throws {
    let http = try stub(["/3/tv/45016": "tmdb_tv_details.json"])
    let m = try await TMDBClient(token: token, http: http).details(id: 45016, kind: .series)
    #expect(query(http.lastURL, "append_to_response") == "credits,keywords,recommendations,similar,images,content_ratings,external_ids")
    #expect(m.kind == .series && m.title == "Bron" && m.year == 2011 && m.runtimeMinutes == 58)
    #expect(m.creators == [Person(id: 900700, name: "Hans Skapare", character: nil, profilePath: "/fakeCreator.jpg")])
    #expect(m.seasons == [SeasonSummary(number: 1, episodeCount: 10, name: "Säsong 1"),
                          SeasonSummary(number: 2, episodeCount: 10, name: "Säsong 2")])
    #expect(m.keywords == ["bridge", "detective"])
    #expect(m.certification == "15" && m.ageLimit == 15)
    #expect(m.imdbID == "tt1733785")
    #expect(m.logoPath == "/fakeTvLogoEn.png")
    #expect(m.cast.count == 4)
}

@Test func overviewFallsBackToEnglish() async throws {
    let http = try stub(["/3/movie/693134": "tmdb_movie_details_no_overview.json",
                         "/3/movie/693134@en-US": "tmdb_movie_overview_en.json"])
    let m = try await TMDBClient(token: token, http: http).details(id: 693134, kind: .movie)
    #expect(http.requests.count == 2)
    #expect(query(http.requests[1].url, "language") == "en-US")
    #expect(query(http.requests[1].url, "append_to_response") == nil)
    #expect(m.overview == "Paul unites with the desert people and seeks revenge against those who destroyed his family.")
    #expect(m.title == "Dune: Del två")   // bara översikten tas från en-US
}

@Test func searchQueryEncodesReservedCharacters() async throws {
    let http = try stub(["/3/search/movie": "tmdb_search_movie.json", "/3/search/tv": "tmdb_search_tv.json"])
    let client = TMDBClient(token: token, http: http)
    for (title, kind) in [("Love, Death + Robots", ContentKind.series), ("Fast & Furious #9", .movie),
                          ("a=b?c/d", .movie)] {
        _ = try await client.search(title, year: nil, kind: kind)
        let url = try #require(http.lastURL)
        #expect(query(url, "query") == title)
        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let rawQuery = try #require(raw.split(separator: "&").first { $0.hasPrefix("query=") })
        #expect(!rawQuery.dropFirst("query=".count).contains { "+&=# ".contains($0) })
        #expect(rawQuery.dropFirst("query=".count).removingPercentEncoding == title)
        #expect(query(url, "include_adult") == "false")
    }
}

@Test func overviewFallbackRethrowsRateLimit() async throws {
    let http = StubHTTPClient(responses: [
        "/3/movie/693134": StubResponse(body: try metadataFixture("tmdb_movie_details_no_overview.json")),
        "/3/movie/693134@en-US": StubResponse(status: 429, headers: ["Retry-After": "3"]),
    ], key: tmdbKey)
    await #expect(throws: TMDBError.rateLimited(retryAfter: 3)) {
        try await TMDBClient(token: token, http: http).details(id: 693134, kind: .movie)
    }
    // Andra fel i reserven ignoreras fortfarande.
    let failing = StubHTTPClient(responses: [
        "/3/movie/693134": StubResponse(body: try metadataFixture("tmdb_movie_details_no_overview.json")),
        "/3/movie/693134@en-US": StubResponse(status: 500),
    ], key: tmdbKey)
    let m = try await TMDBClient(token: token, http: failing).details(id: 693134, kind: .movie)
    #expect(m.overview == nil && m.title == "Dune: Del två")
}

@Test func detailsTruncateCastAndRelatedTitles() async throws {
    let body: [String: Any] = [
        "id": 1, "title": "Lång", "overview": "Text",
        "credits": ["cast": (1...40).map { ["id": $0, "name": "Person \($0)"] }],
        "recommendations": ["results": (1...45).map { ["id": $0] }],
        "similar": ["results": (100...130).map { ["id": $0] }],
    ]
    let http = StubHTTPClient(responses: ["/3/movie/1": StubResponse(body: try JSONSerialization.data(withJSONObject: body))],
                              key: tmdbKey)
    let m = try await TMDBClient(token: token, http: http).details(id: 1, kind: .movie)
    #expect(m.cast.count == 15 && m.cast.first?.id == 1)
    #expect(m.recommendations == Array(1...20))
    #expect(m.similar == Array(100...119))
}

@Test func rateLimitedSurfacesRetryAfter() async {
    let http = StubHTTPClient(responses: ["/3/movie/1": StubResponse(status: 429, headers: ["retry-after": "2"])], key: tmdbKey)
    await #expect(throws: TMDBError.rateLimited(retryAfter: 2)) {
        try await TMDBClient(token: token, http: http).details(id: 1, kind: .movie)
    }
}

@Test func httpStatusesMapToTMDBErrors() async {
    func client(_ status: Int) -> TMDBClient {
        TMDBClient(token: token, http: StubHTTPClient(responses: ["/3/movie/1": StubResponse(status: status)], key: tmdbKey))
    }
    await #expect(throws: TMDBError.unauthorized) { try await client(401).details(id: 1, kind: .movie) }
    await #expect(throws: TMDBError.notFound) { try await client(404).details(id: 1, kind: .movie) }
    await #expect(throws: TMDBError.rateLimited(retryAfter: nil)) { try await client(429).details(id: 1, kind: .movie) }
    await #expect(throws: TMDBError.http(503)) { try await client(503).details(id: 1, kind: .movie) }
    await #expect(throws: TMDBError.invalidResponse) { try await client(200).details(id: 1, kind: .movie) }
    await #expect(throws: TMDBError.unavailable) {
        try await TMDBClient(token: token, http: FailingHTTPClient(URLError(.timedOut))).details(id: 1, kind: .movie)
    }
}

@Test func trendingAndPopularReturnIDs() async throws {
    let http = try stub(["/3/trending/movie/week": "tmdb_trending.json", "/3/trending/tv/day": "tmdb_trending.json",
                         "/3/movie/popular": "tmdb_popular.json"])
    let client = TMDBClient(token: token, http: http)
    #expect(try await client.trending(kind: .movie) == [693134, 438631, 823464])
    #expect(try await client.trending(kind: .series, window: .day) == [693134, 438631, 823464])
    #expect(try await client.popular(kind: .movie) == [823464, 693134])
    #expect(query(http.lastURL, "region") == "SE")
}

@Test func imageURLsUseSizes() {
    #expect(TMDBImage.url(path: "/abc.jpg", size: .w342).absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
    #expect(TMDBImage.url(path: "/abc.jpg", size: .original).absoluteString == "https://image.tmdb.org/t/p/original/abc.jpg")
    #expect(TMDBImage.url(path: "abc.jpg", size: .w1280).absoluteString == "https://image.tmdb.org/t/p/w1280/abc.jpg")
}

@Test func errorDescriptionsContainNoSecrets() {
    let all: [TMDBError] = [.unauthorized, .rateLimited(retryAfter: 1), .notFound, .http(500), .invalidResponse, .unavailable]
    for e in all { #expect(!String(describing: e).contains("://") && !String(describing: e).contains(token)) }
}
