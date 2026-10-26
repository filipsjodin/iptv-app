import Core
import Foundation
import Metadata
import Providers
import ProvidersTestSupport

@testable import Library

let metaT0 = Date(timeIntervalSince1970: 1_700_000_000)
let metaPID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EE")!
let metaOtherPID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EF")!
let day: TimeInterval = 24 * 3600

func metaMovie(_ id: String, _ title: String, year: Int? = nil, tmdb: Int? = nil, poster: String? = nil) -> Movie {
    Movie(providerID: id, title: title, year: year, posterURL: poster.flatMap { URL(string: $0) }, container: "mkv",
          tmdbID: tmdb, locator: .xtream(kind: .movie, streamID: id, container: "mkv"))
}

func metaSeries(_ id: String, _ title: String, year: Int? = nil, tmdb: Int? = nil) -> Series {
    Series(providerID: id, title: title, year: year, tmdbID: tmdb)
}

struct MetaFixture {
    let db: AppDatabase
    let library: LibraryStore
    let store: MetadataStore
}

/// Databas i minnet med en spellista (`metaPID`) och, om angivet, en andra (`metaOtherPID`).
func metaFixture(movies: [Movie] = [], series: [Series] = [], otherMovies: [Movie]? = nil) throws -> MetaFixture {
    let db = try AppDatabase.inMemory()
    let library = LibraryStore(db: db)
    try library.upsertPlaylist(Playlist(id: metaPID, name: "A", kind: .xtream, createdAt: metaT0))
    try library.replaceCatalog(ProviderCatalog(movies: movies, series: series), playlistID: metaPID, now: metaT0)
    if let otherMovies {
        try library.upsertPlaylist(Playlist(id: metaOtherPID, name: "B", kind: .xtream, createdAt: metaT0))
        try library.replaceCatalog(ProviderCatalog(movies: otherMovies), playlistID: metaOtherPID, now: metaT0)
    }
    return MetaFixture(db: db, library: library, store: MetadataStore(db: db))
}

func sampleMetadata(_ id: Int, kind: ContentKind = .movie, title: String = "Titel", genres: [Int] = [],
                    imdbID: String? = nil) -> TitleMetadata {
    TitleMetadata(tmdbID: id, kind: kind, title: title, overview: "Översikt", year: 2010,
                  genres: genres.map { Genre(id: $0, name: "G\($0)") }, imdbID: imdbID, language: "sv-SE")
}

// MARK: - Klocka och sömn

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = metaT0) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    var closure: @Sendable () -> Date { { [self] in now } }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Duration] = []
    var durations: [Duration] { lock.lock(); defer { lock.unlock() }; return log }
    var closure: @Sendable (Duration) async -> Void {
        { [self] d in lock.withLock { log.append(d) } }
    }
}

// MARK: - Stubbad TMDB

/// Svarar per nyckel: `/3/search/movie|Titel|2010` (år bara när det skickas), `/3/movie/27205`,
/// `omdb|tt123`. Varje nyckel har en kö av svar där det sista upprepas; okänd nyckel ger 404.
/// Mäter högsta antal samtidiga anrop.
final class TMDBStub: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [StubResponse]] = [:]
    private var log: [String] = []
    private var inFlight = 0
    private var peak = 0
    private let delay: Duration?

    init(delay: Duration? = nil) { self.delay = delay }

    func on(_ key: String, _ responses: StubResponse...) {
        lock.lock(); queues[key] = responses; lock.unlock()
    }

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func count(_ key: String) -> Int { requests.filter { $0 == key }.count }

    static func key(_ url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = c?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if url.host?.contains("omdbapi") == true { return "omdb|" + (value("i") ?? "") }
        var key = c?.path ?? ""
        if key.contains("/search/") {
            key += "|" + (value("query") ?? "")
            if let year = value("year") ?? value("first_air_date_year") { key += "|" + year }
        }
        return key
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        let (data, status, _) = try await get(url, headers: [:])
        return (data, status)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        let key = Self.key(url)
        let response: StubResponse = lock.withLock {
            log.append(key)
            inFlight += 1
            peak = max(peak, inFlight)
            guard var queue = queues[key], let first = queue.first else { return StubResponse(status: 404) }
            if queue.count > 1 { queue.removeFirst(); queues[key] = queue }
            return first
        }
        if let delay { try? await Task.sleep(for: delay) }
        lock.withLock { inFlight -= 1 }
        return (response.body, response.status, response.headers)
    }
}

func searchResponse(_ hits: [(id: Int, title: String, date: String)], series: Bool = false) -> StubResponse {
    let results: [[String: Any]] = hits.map { hit in
        series ? ["id": hit.id, "name": hit.title, "first_air_date": hit.date, "popularity": 10.0]
            : ["id": hit.id, "title": hit.title, "release_date": hit.date, "popularity": 10.0]
    }
    return StubResponse(body: try! JSONSerialization.data(withJSONObject: ["results": results]))
}

func detailsResponse(_ id: Int, title: String, genres: [Int], series: Bool = false, imdbID: String? = nil)
    -> StubResponse {
    var body: [String: Any] = [
        "id": id, "overview": "Översikt \(id)",
        "genres": genres.map { ["id": $0, "name": "G\($0)"] },
    ]
    if series {
        body["name"] = title
        body["first_air_date"] = "2011-09-21"
    } else {
        body["title"] = title
        body["release_date"] = "2010-07-15"
    }
    if let imdbID { body["external_ids"] = ["imdb_id": imdbID] }
    return StubResponse(body: try! JSONSerialization.data(withJSONObject: body))
}

func idsResponse(_ ids: [Int]) -> StubResponse {
    StubResponse(body: try! JSONSerialization.data(withJSONObject: ["results": ids.map { ["id": $0] }]))
}

func tmdb(_ stub: TMDBStub) -> TMDBClient {
    TMDBClient(token: "test-token-not-real", http: stub)
}
