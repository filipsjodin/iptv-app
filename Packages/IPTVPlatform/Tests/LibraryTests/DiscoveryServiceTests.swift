import Core
import Discovery
import Foundation
import Metadata
import Personal
import PlaybackCore
import Providers
import Testing

@testable import Library

// MARK: - Hjälpare

private struct DiscoveryFixture {
    let library: LibraryStore
    let store: MetadataStore
    let service: DiscoveryService
}

private func discoveryFixture(movies: [Movie] = [], series: [Series] = [], live: [LiveStream] = []) throws
    -> DiscoveryFixture {
    let db = try AppDatabase.inMemory()
    let library = LibraryStore(db: db)
    try library.upsertPlaylist(Playlist(id: metaPID, name: "A", kind: .xtream, createdAt: metaT0))
    try library.replaceCatalog(ProviderCatalog(movies: movies, series: series, live: live), playlistID: metaPID,
                               now: metaT0)
    let store = MetadataStore(db: db)
    return DiscoveryFixture(library: library, store: store, service: DiscoveryService(library: library, metadata: store))
}

private func meta(_ id: Int, kind: ContentKind = .movie, genres: [Int] = [], cast: [Int] = [], directors: [Int] = [],
                  creators: [Int] = [], keywords: [String] = [], age: Int? = nil, popularity: Double? = nil,
                  similar: [Int] = [], recommendations: [Int] = []) -> TitleMetadata {
    TitleMetadata(tmdbID: id, kind: kind, title: "T\(id)", overview: "Översikt med \"citat\" och , komma",
                  genres: genres.map { Genre(id: $0, name: "Genre \($0)") }, popularity: popularity,
                  cast: cast.map { Person(id: $0, name: "P\($0)", character: "Roll") },
                  directors: directors.map { Person(id: $0, name: "D\($0)") },
                  creators: creators.map { Person(id: $0, name: "C\($0)") }, keywords: keywords, ageLimit: age,
                  recommendations: recommendations, similar: similar, language: "sv-SE")
}

private func movie(_ id: String, _ title: String, tmdb: Int? = nil, added: Double? = nil) -> Movie {
    metaMovie(id, title, tmdb: tmdb, added: added.map { metaT0 + $0 })
}

private func profile(kids: Bool) -> Profile {
    Profile(playlistID: metaPID, name: kids ? "Barn" : "Vuxen", avatar: "star", isKids: kids, createdAt: metaT0)
}

private func personalStore() -> UserDefaultsPersonalStore {
    UserDefaultsPersonalStore(defaults: UserDefaults(suiteName: "discovery.\(UUID())")!, key: "personal")
}

private func ids(_ rows: [(RowID, [LibraryItem])]) -> [RowID] { rows.map(\.0) }

// MARK: - Kandidater

@Test func candidatesJoinMatchesAndMetadata() throws {
    let f = try discoveryFixture(
        movies: [movie("m1", "Med id", tmdb: 1, added: 10), movie("m2", "Matchad"), movie("m3", "Utan metadata"),
                 movie("m4", "Leverantören vinner", tmdb: 4)],
        series: [metaSeries("s1", "Serie", tmdb: 1)])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m2", tmdbID: 2, confidence: 0.9, now: metaT0)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m4", tmdbID: 2, confidence: 0.9, now: metaT0)
    try f.store.saveMetadata(meta(1, genres: [28, 12], cast: [10, 11], directors: [20], keywords: ["rymd", "a,b"],
                                  age: 11, popularity: 50), now: metaT0)
    try f.store.saveMetadata(meta(2, genres: [18], age: 15, popularity: 80), now: metaT0)
    try f.store.saveMetadata(meta(4, popularity: 5), now: metaT0)
    try f.store.saveMetadata(meta(1, kind: .series, genres: [10765], creators: [30], age: 7, popularity: 3), now: metaT0)

    let movies = try f.service.candidates(playlistID: metaPID, kind: .movie)
    // Ingen särskild ordning (rankningen sköts av motorn).
    #expect(movies.map(\.ref.providerID).sorted() == ["m1", "m2", "m3", "m4"])
    let m1 = try #require(movies.first { $0.ref.providerID == "m1" })
    #expect(m1.ref == ItemRef(kind: .movie, providerID: "m1"))
    #expect(m1.tmdbID == 1 && m1.title == "Med id")
    #expect(m1.genres == [28, 12] && m1.castIDs == [10, 11] && m1.directorIDs == [20])
    #expect(m1.keywords == ["rymd", "a,b"])
    #expect(m1.ageLimit == 11 && m1.popularity == 50 && m1.addedAt == metaT0 + 10)
    let m2 = try #require(movies.first { $0.ref.providerID == "m2" })
    #expect(m2.tmdbID == 2 && m2.genres == [18] && m2.ageLimit == 15)
    let m4 = try #require(movies.first { $0.ref.providerID == "m4" })
    #expect(m4.tmdbID == 4 && m4.popularity == 5 && m4.genres.isEmpty)
    let m3 = try #require(movies.first { $0.ref.providerID == "m3" })
    #expect(m3.tmdbID == nil && m3.ageLimit == nil && m3.popularity == nil && m3.genres.isEmpty && m3.addedAt == nil)

    let series = try f.service.candidates(playlistID: metaPID, kind: .series)
    #expect(series.count == 1)
    #expect(series[0].directorIDs == [30] && series[0].genres == [10765] && series[0].ageLimit == 7)
    #expect(try f.service.candidates(playlistID: metaPID, kind: .live).isEmpty)
    #expect(try f.service.candidates(playlistID: UUID(), kind: .movie).isEmpty)
}

@Test func candidatesAreCachedUntilInvalidated() throws {
    let f = try discoveryFixture(movies: [movie("m1", "Film")])
    #expect(try f.service.candidates(playlistID: metaPID, kind: .movie)[0].tmdbID == nil)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 9, confidence: 0.9, now: metaT0)
    try f.store.saveMetadata(meta(9, age: 7), now: metaT0)
    // Cachen gäller tills den töms.
    #expect(try f.service.candidates(playlistID: metaPID, kind: .movie)[0].tmdbID == nil)
    f.service.invalidate(playlistID: metaPID)
    let c = try f.service.candidates(playlistID: metaPID, kind: .movie)[0]
    #expect(c.tmdbID == 9 && c.ageLimit == 7)
}

// MARK: - Barnprofil

@Test func kidsProfileHidesUnratedEverywhere() throws {
    let f = try discoveryFixture(
        movies: [movie("m7", "Film sju", tmdb: 7, added: 1), movie("m15", "Film femton", tmdb: 15, added: 2),
                 movie("mx", "Film okänd", tmdb: 99, added: 3), movie("mn", "Film utan metadata", added: 4)],
        live: [LiveStream(providerID: "l1", name: "Film kanal",
                          locator: .xtream(kind: .live, streamID: "l1", container: "ts"))])
    let ages: [(Int, Int?)] = [(7, 7), (15, 15), (99, nil)]
    for (id, age) in ages {
        try f.store.saveMetadata(meta(id, genres: [16], cast: [500], keywords: ["djur"], age: age,
                                      popularity: Double(id), similar: [7, 15, 99]), now: metaT0)
    }
    try f.store.saveList("trending.movie", ids: [99, 15, 7], now: metaT0)
    let personal = personalStore()
    _ = personal.toggleMyList(ItemRef(kind: .movie, providerID: "m15"))
    _ = personal.toggleMyList(ItemRef(kind: .movie, providerID: "m7"))
    _ = personal.toggleMyList(ItemRef(kind: .movie, providerID: "mx"))
    let state = InMemoryUserStateStore()

    let kidsRows = try f.service.rows(playlistID: metaPID, profile: profile(kids: true), personal: personal,
                                      userState: state, kinds: [.movie, .series, .live])
    #expect(!kidsRows.isEmpty)
    for (id, items) in kidsRows { #expect(items.map(\.providerID) == ["m7"], "rad \(id)") }
    // För dig saknas: m7 ligger i Min lista och För dig visar bara nya titlar.
    #expect(ids(kidsRows) == [.topTen(.movie), .recentlyAdded(.movie), .myList, .genre(16, .movie)])

    // Vuxenprofilen ser allt.
    let adultRows = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personal,
                                       userState: state, kinds: [.movie])
    let adult = Dictionary(adultRows, uniquingKeysWith: { a, _ in a })
    #expect(adult[.topTen(.movie)]?.map(\.providerID) == ["mx", "m15", "m7"])
    #expect(adult[.myList]?.map(\.providerID) == ["mx", "m7", "m15"])
    #expect(adult[.recentlyAdded(.movie)]?.map(\.providerID) == ["mn", "mx", "m15", "m7"])

    // Sökning: barn ser bara m7 (inte livekanaler); vuxna ser allt.
    #expect(try f.service.search("film", playlistID: metaPID, limit: 10, kids: true).map(\.providerID) == ["m7"])
    #expect(try f.service.search("film", playlistID: metaPID, kind: .live, limit: 10, kids: true).isEmpty)
    #expect(try f.service.search("film", playlistID: metaPID, limit: 10).count == 5)
    #expect(try f.service.search("film", playlistID: metaPID, limit: 1, kids: true).map(\.providerID) == ["m7"])

    // Liknande och per person.
    #expect(try f.service.similar(playlistID: metaPID, kind: .movie, providerID: "m15", limit: 10, kids: true)
        .map(\.providerID) == ["m7"])
    #expect(try f.service.similar(playlistID: metaPID, kind: .movie, providerID: "m15", limit: 10)
        .map(\.providerID) == ["m7", "mx"])
    #expect(try f.service.byPerson(playlistID: metaPID, personID: 500, kids: true).map(\.providerID) == ["m7"])
    #expect(try f.service.byPerson(playlistID: metaPID, personID: 500).map(\.providerID) == ["mx", "m15", "m7"])
}

// MARK: - Rader

@Test func rowsOrderAndGenreSelection() throws {
    // Nio filmgenrer (genre g finns i g titlar) och två seriegenrer: de 8 största filmgenrerna (2...9) visas.
    var movies: [Movie] = []
    for i in 0..<9 { movies.append(movie("m\(i)", "Film \(i)", tmdb: 100 + i, added: Double(i))) }
    let f = try discoveryFixture(movies: movies,
                                 series: [metaSeries("s1", "Serie ett", tmdb: 1), metaSeries("s2", "Serie två", tmdb: 2)])
    for i in 0..<9 {
        // Titel i har genrerna g där g > i, så genre g förekommer i g titlar.
        try f.store.saveMetadata(meta(100 + i, genres: Array((i + 1)...9), age: 7, popularity: Double(i)), now: metaT0)
    }
    try f.store.saveMetadata(meta(1, kind: .series, genres: [10765, 18], age: 7, popularity: 2), now: metaT0)
    try f.store.saveMetadata(meta(2, kind: .series, genres: [18], age: 7, popularity: 1), now: metaT0)
    try f.store.saveList("trending.movie", ids: [100], now: metaT0)
    try f.store.saveList("trending.series", ids: [2], now: metaT0)
    let personal = personalStore()
    _ = personal.toggleMyList(ItemRef(kind: .series, providerID: "s1"))

    let rows = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personal,
                                  userState: InMemoryUserStateStore(), kinds: [.movie, .series])
    let movieGenres: [RowID] = [9, 8, 7, 6, 5, 4, 3, 2].map { .genre($0, .movie) }
    #expect(ids(rows) == [.forYou, .topTen(.movie), .topTen(.series), .recentlyAdded(.movie), .myList]
        + movieGenres + [.genre(18, .series), .genre(10765, .series)])
    let byID = Dictionary(rows, uniquingKeysWith: { a, _ in a })
    // Genrerader sorteras på popularitet.
    #expect(byID[.genre(2, .movie)]?.map(\.providerID) == ["m1", "m0"])
    #expect(byID[.genre(18, .series)]?.map(\.providerID) == ["s1", "s2"])
    #expect(byID[.recentlyAdded(.movie)]?.first?.providerID == "m8")
    #expect(byID[.forYou]?.count == 10)   // allt utom Min lista-titeln s1
    #expect(f.service.genreName(9) == "Genre 9")
    #expect(f.service.genreName(12345) == nil)

    // Bara filmer.
    let movieOnly = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personal,
                                       userState: InMemoryUserStateStore(), kinds: [.movie])
    #expect(ids(movieOnly) == [.forYou, .topTen(.movie), .recentlyAdded(.movie)] + movieGenres)
}

@Test func topTenUsesCachedTMDBList() throws {
    var movies: [Movie] = []
    for i in 0..<12 { movies.append(movie("m\(i)", "Film \(i)", tmdb: i < 6 ? 200 + i : nil)) }
    let f = try discoveryFixture(movies: movies, series: [metaSeries("s1", "Serie", tmdb: 1), metaSeries("s2", "Två")])
    // Hälften via matchning.
    for i in 6..<12 {
        try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m\(i)", tmdbID: 200 + i, confidence: 0.9,
                              now: metaT0)
    }
    try f.store.saveMatch(playlistID: metaPID, kind: .series, providerID: "s2", tmdbID: 2, confidence: 0.9, now: metaT0)
    // Listan rankar 999 (saknas i spellistan) och alla tolv filmer i omvänd ordning.
    try f.store.saveList("trending.movie", ids: [999] + (0..<12).reversed().map { 200 + $0 }, now: metaT0)
    try f.store.saveList("popular.movie.SE", ids: [200], now: metaT0)
    // Trending för serier saknas: populärlistan används.
    try f.store.saveList("popular.series.SE", ids: [2, 1], now: metaT0)

    let rows = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personalStore(),
                                  userState: InMemoryUserStateStore(), kinds: [.movie, .series])
    let byID = Dictionary(rows, uniquingKeysWith: { a, _ in a })
    #expect(byID[.topTen(.movie)]?.map(\.providerID) == (2..<12).reversed().map { "m\($0)" })
    #expect(byID[.topTen(.series)]?.map(\.providerID) == ["s2", "s1"])
    // Utan listor: inga topp 10-rader.
    let empty = try discoveryFixture(movies: [movie("m1", "Film", tmdb: 1)])
    let none = try empty.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personalStore(),
                                      userState: InMemoryUserStateStore(), kinds: [.movie, .series])
    #expect(!ids(none).contains(.topTen(.movie)) && !ids(none).contains(.topTen(.series)))
}

@Test func myListRowOnlyExistingTitles() throws {
    let f = try discoveryFixture(movies: [movie("m1", "Film"), movie("m2", "Annan")],
                                 series: [metaSeries("s1", "Serie")])
    let personal = personalStore()
    for ref in [ItemRef(kind: .movie, providerID: "m1"), ItemRef(kind: .movie, providerID: "borta"),
                ItemRef(kind: .live, providerID: "l1"), ItemRef(kind: .series, providerID: "s1"),
                ItemRef(kind: .series, providerID: "m2")] {
        _ = personal.toggleMyList(ref)
    }
    let rows = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personal,
                                  userState: InMemoryUserStateStore(), kinds: [.movie, .series])
    let byID = Dictionary(rows, uniquingKeysWith: { a, _ in a })
    // Nyast först; borttagna titlar, live och fel typ utelämnas.
    #expect(byID[.myList]?.map(\.id) == ["series:s1", "movie:m1"])
    // Bara typer som ingår i `kinds`.
    let movieOnly = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personal,
                                       userState: InMemoryUserStateStore(), kinds: [.movie])
    #expect(Dictionary(movieOnly, uniquingKeysWith: { a, _ in a })[.myList]?.map(\.id) == ["movie:m1"])
}

// MARK: - Signaler

@Test func signalsMapEpisodesToSeriesAndCollectRecommendations() throws {
    let f = try discoveryFixture(movies: [movie("m1", "Sedd", tmdb: 1), movie("m2", "Halv", tmdb: 2),
                                          movie("m3", "Rek", tmdb: 3), movie("m4", "Annan", tmdb: 4)],
                                 series: [metaSeries("s1", "Serie", tmdb: 10)])
    try f.store.saveMetadata(meta(1, genres: [1], popularity: 1, recommendations: [3]), now: metaT0)
    try f.store.saveMetadata(meta(2, genres: [2], popularity: 2, recommendations: [4]), now: metaT0)
    try f.store.saveMetadata(meta(3, genres: [3], popularity: 3), now: metaT0)
    try f.store.saveMetadata(meta(4, genres: [4], popularity: 4), now: metaT0)
    try f.store.saveMetadata(meta(10, kind: .series, genres: [5], popularity: 1, recommendations: [77]), now: metaT0)
    let state = InMemoryUserStateStore()
    func save(_ id: String, series: String? = nil, _ pos: Double, _ dur: Double?, watched: Bool = false) {
        state.save(WatchProgress(key: ProgressKey(playlistID: metaPID, kind: series == nil ? .movie : .series,
                                                  providerID: id, seriesProviderID: series),
                                 position: pos, duration: dur, watched: watched, updatedAt: metaT0))
    }
    save("m1", 95, 100, watched: true)
    save("m2", 30, 100)
    save("e1", series: "s1", 20, 100)
    save("e2", series: "s1", 95, 100)
    save("x", 10, nil)
    state.save(WatchProgress(key: ProgressKey(playlistID: UUID(), kind: .movie, providerID: "m4"), position: 99,
                             duration: 100, watched: true, updatedAt: metaT0))

    let snaps: [ContentKind: DiscoveryService.Snapshot] = [
        .movie: try f.service.snapshot(playlistID: metaPID, kind: .movie),
        .series: try f.service.snapshot(playlistID: metaPID, kind: .series),
    ]
    let s = try f.service.signals(playlistID: metaPID, personal: personalStore(), userState: state, snaps: snaps)
    #expect(s.watched[ItemRef(kind: .movie, providerID: "m1")] == 1)
    #expect(s.watched[ItemRef(kind: .movie, providerID: "m2")] == 0.3)
    #expect(s.watched[ItemRef(kind: .series, providerID: "s1")] == 0.95)
    #expect(s.watched[ItemRef(kind: .movie, providerID: "x")] == 0)
    #expect(s.watched[ItemRef(kind: .movie, providerID: "m4")] == nil)
    // Bara titlar med positiv vikt (sedda ≥ 0,9) ger rekommendationer.
    #expect(s.recommendationsFor == [ItemRef(kind: .movie, providerID: "m1"): [3],
                                     ItemRef(kind: .series, providerID: "s1"): [77]])

    // För dig: m3 (rekommenderad av sedda m1) före m4 trots lägre popularitet; sedda titlar visas inte.
    let rows = try f.service.rows(playlistID: metaPID, profile: profile(kids: false), personal: personalStore(),
                                  userState: state, kinds: [.movie, .series])
    #expect(Dictionary(rows, uniquingKeysWith: { a, _ in a })[.forYou]?.map(\.providerID) == ["m3", "m4"])
}

// MARK: - Egenskapsläsaren

@Test func featureScannerMatchesJSONDecoder() throws {
    // Verklig blob från saveMetadata (alla fält, sorterade nycklar) plus handskrivna kantfall.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let full = meta(1, kind: .series, genres: [28, 12], cast: [5, 6], directors: [9], creators: [3],
                    keywords: ["rymd", "a,b", "citat \"x\"", "ö\n"], age: 7, popularity: 12.5, similar: [1, 2],
                    recommendations: [3])
    let cases = [
        String(decoding: try encoder.encode(full), as: UTF8.self),
        #"{"popularity":1.5e-05,"genres":[],"cast":[],"keywords":[]}"#,
        #"{"ageLimit":0,"popularity":-3,"genres":[{"name":"x","id":-1}],"cast":[{"id":1},{"id":2,"extra":{"id":99,"arr":[1,{"a":"]"}]}}],"directors":[],"creators":[{"id":3,"name":"C"}],"imdbRating":null}"#,
        #"{"overview":"{ [ \" ] } \\","keywords":["\u00e4\/\\"],"seasons":[{"number":1,"episodeCount":3}]}"#,
        #"{}"#,
        #" { "ageLimit" : 11 , "genres" : [ { "id" : 4 } ] } "#,
    ]
    for json in cases {
        var text = json
        let fast = text.withUTF8 { buf -> Features? in
            var scanner = FeatureScanner(bytes: buf)
            return scanner.features()
        }
        let slow = try JSONDecoder().decode(Features.self, from: Data(json.utf8))
        #expect(fast == slow, "\(json)")
        #expect(Features.parse(json) == slow)
    }
    let first = Features.parse(cases[0])
    #expect(first.age == 7 && first.popularity == 12.5 && first.genres == [28, 12] && first.cast == [5, 6])
    #expect(first.directors == [9, 3] && first.keywords == ["rymd", "a,b", "citat \"x\"", "ö\n"])
    #expect(Features.parse(cases[2]).directors == [3] && Features.parse(cases[2]).cast == [1, 2])
    #expect(Features.parse(cases[3]).keywords == ["ä/\\"])
    // Oväntat format: läsaren ger upp och JSONDecoder avgör.
    for bad in [#"{"ageLimit":1"#, "[]", #"{"ageLimit":1.5}"#, #"{"genres":[{"name":"utan id"}]}"#] {
        var text = bad
        #expect(text.withUTF8 { buf -> Features? in
            var scanner = FeatureScanner(bytes: buf)
            return scanner.features()
        } == nil)
    }
    #expect(Features.parse("trasig") == Features())
}
