import Core
import Foundation
import GRDB
import Metadata
import Providers
import ProvidersTestSupport
import Testing

@testable import Library

private func service(_ f: MetaFixture, _ stub: TMDBStub?, clock: TestClock = TestClock(),
                     sleep: SleepRecorder = SleepRecorder(), omdb: OMDbClient? = nil) -> MetadataService {
    MetadataService(store: f.store, library: f.library, client: stub.map(tmdb), omdb: omdb, now: clock.closure,
                    sleep: sleep.closure)
}

@Test func enrichMatchesAndCaches() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception (2010)"), metaMovie("m2", "Arrival", year: 2016),
                                     metaMovie("m3", "Twins")])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception|2010", searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/search/movie|Arrival|2016", searchResponse([(329865, "Arrival", "2016-11-10")]))
    stub.on("/3/search/movie|Twins", searchResponse([(9493, "Twins", "1988-12-09"), (77777, "Twins", "2005-01-01")]))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28, 878]))
    stub.on("/3/movie/329865", detailsResponse(329865, title: "Arrival", genres: [18, 878]))
    let s = service(f, stub)

    #expect(await s.enrich(playlistID: metaPID) == 2)
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1")?.tmdbID == 27205)
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m2")?.tmdbID == 329865)
    let ambiguous = try #require(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m3"))
    #expect(ambiguous.tmdbID == nil && ambiguous.attemptedAt == metaT0)
    #expect(try f.store.metadata(kind: .movie, tmdbID: 27205)?.title == "Inception")
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 878, limit: 10).map(\.providerID) == ["m2", "m1"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 28, limit: 10).map(\.providerID) == ["m1"])

    // Andra körningen har inget att göra.
    let before = stub.requests.count
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(stub.requests.count == before)
    // Cachen används av den lata hämtningen.
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m2")?.genres.map(\.id) == [18, 878])
    #expect(stub.requests.count == before)
}

@Test func enrichMatchesSeriesAndProviderIDSkipsSearch() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Okänd titel", tmdb: 603)], series: [metaSeries("s1", "Bron")])
    let stub = TMDBStub()
    stub.on("/3/movie/603", detailsResponse(603, title: "The Matrix", genres: [28]))
    stub.on("/3/search/tv|Bron", searchResponse([(45016, "Bron", "2011-09-21")], series: true))
    stub.on("/3/tv/45016", detailsResponse(45016, title: "Bron", genres: [80], series: true))
    let s = service(f, stub)
    #expect(await s.enrich(playlistID: metaPID) == 2)
    #expect(!stub.requests.contains { $0.hasPrefix("/3/search/movie") })
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1")?.confidence == 1)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .series, providerID: "s1") == 45016)
    #expect(try f.store.metadata(kind: .series, tmdbID: 45016)?.title == "Bron")
}

@Test func searchRetriesWithoutYear() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Dune", year: 2022)])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Dune|2022", searchResponse([]))
    stub.on("/3/search/movie|Dune", searchResponse([(438631, "Dune", "2021-09-15")]))
    stub.on("/3/movie/438631", detailsResponse(438631, title: "Dune", genres: [878]))
    #expect(await service(f, stub).enrich(playlistID: metaPID) == 1)
    #expect(Array(stub.requests.prefix(2)) == ["/3/search/movie|Dune|2022", "/3/search/movie|Dune"])
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "m1") == 438631)
}

@Test func enrichUsesAtMostFourConcurrentRequests() async throws {
    let movies = (1...12).map { metaMovie("m\($0)", "Film \($0)", tmdb: 1000 + $0) }
    let f = try metaFixture(movies: movies)
    let stub = TMDBStub(delay: .milliseconds(20))
    for i in 1...12 { stub.on("/3/movie/\(1000 + i)", detailsResponse(1000 + i, title: "Film \(i)", genres: [1])) }
    #expect(await service(f, stub).enrich(playlistID: metaPID) == 12)
    #expect(stub.maxInFlight <= MetadataService.maxConcurrent)
    #expect(stub.maxInFlight >= 1)
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 1, limit: 50).count == 12)
}

@Test func enrichBatchLimitsWork() async throws {
    let f = try metaFixture(movies: (1...5).map { (i: Int) in metaMovie("m\(i)", "Film \(i)", tmdb: i) })
    let stub = TMDBStub()
    for i in 1...5 { stub.on("/3/movie/\(i)", detailsResponse(i, title: "Film \(i)", genres: [])) }
    let s = service(f, stub)
    #expect(await s.enrich(playlistID: metaPID, batch: 2) == 2)
    #expect(await s.enrich(playlistID: metaPID, batch: 10) == 3)
}

@Test func rateLimitPausesAndRetries() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", year: 2010)])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception|2010", StubResponse(status: 429, headers: ["Retry-After": "2"]),
            searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/movie/27205", StubResponse(status: 429), detailsResponse(27205, title: "Inception", genres: [28]))
    let clock = TestClock()
    let sleep = SleepRecorder(advancing: clock)
    #expect(await service(f, stub, clock: clock, sleep: sleep).enrich(playlistID: metaPID) == 1)
    #expect(sleep.durations == [.seconds(2), .seconds(5)])
    #expect(try f.store.metadata(kind: .movie, tmdbID: 27205) != nil)
}

@Test func rateLimitExhaustedRecordsAttempt() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception")])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception", StubResponse(status: 429, headers: ["Retry-After": "1"]))
    let sleep = SleepRecorder()
    let clock = TestClock()
    let s = service(f, stub, clock: clock, sleep: sleep)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(sleep.durations.count == MetadataService.maxRateLimitRetries)
    #expect(stub.count("/3/search/movie|Inception") == 1 + MetadataService.maxRateLimitRetries)
    let attempt = try #require(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1"))
    #expect(attempt.tmdbID == nil)
    #expect(await s.isEnabled)

    // Vilar i 7 dagar.
    clock.advance(6 * day)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(stub.count("/3/search/movie|Inception") == 1 + MetadataService.maxRateLimitRetries)
    clock.advance(2 * day)
    stub.on("/3/search/movie|Inception", searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]))
    #expect(await s.enrich(playlistID: metaPID) == 1)
}

@Test func unauthorizedStopsEnrichmentWithoutThrowing() async throws {
    let f = try metaFixture(movies: (1...6).map { metaMovie("m\($0)", "Film \($0)") })
    let stub = TMDBStub()
    for i in 1...6 { stub.on("/3/search/movie|Film \(i)", StubResponse(status: 401)) }
    let s = service(f, stub)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(await s.isEnabled == false)
    #expect(stub.requests.count <= MetadataService.maxConcurrent)
    // Inga försök registreras, och inget fler anrop görs under sessionen.
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    let count = stub.requests.count
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    await s.refreshLists()
    #expect(stub.requests.count == count)
}

@Test func transientFailureIsRetriedNextRun() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception")])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception", StubResponse(status: 503), searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]))
    let s = service(f, stub)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    #expect(await s.enrich(playlistID: metaPID) == 1)
}

@Test func metadataFetchesLazilyAndHonoursTTL() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", year: 2010)])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception|2010", searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]),
            detailsResponse(27205, title: "Inception (ny)", genres: [28]))
    let clock = TestClock()
    let s = service(f, stub, clock: clock)

    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Inception")
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1")?.tmdbID == 27205)
    clock.advance(29 * day)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Inception")
    #expect(stub.count("/3/movie/27205") == 1)
    clock.advance(2 * day)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Inception (ny)")
    #expect(stub.count("/3/movie/27205") == 2)
    #expect(await s.metadata(playlistID: metaPID, kind: .live, providerID: "m1") == nil)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "saknas") == nil)
}

@Test func staleCacheUsedWhenTMDBFails() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", tmdb: 27205)])
    try f.store.saveMetadata(sampleMetadata(27205, title: "Gammal", genres: [28]), now: metaT0)
    let stub = TMDBStub()
    stub.on("/3/movie/27205", StubResponse(status: 500))
    let clock = TestClock(metaT0 + 31 * day)
    let s = service(f, stub, clock: clock)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Gammal")
    #expect(stub.count("/3/movie/27205") == 1)
    stub.on("/3/movie/27205", StubResponse(status: 429, headers: ["Retry-After": "30"]))
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Gammal")
    #expect(await s.isEnabled)
}

@Test func missingTokenDisablesEnrichmentGracefully() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", tmdb: 27205)])
    let s = service(f, nil)
    #expect(await s.isEnabled == false)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    await s.refreshLists()
    #expect(try f.store.list("trending.movie") == nil)
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
}

@Test func omdbRatingsAreCachedWithMetadata() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", tmdb: 27205), metaMovie("m2", "Utan", tmdb: 5)])
    let stub = TMDBStub()
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28], imdbID: "tt1375666"))
    stub.on("/3/movie/5", detailsResponse(5, title: "Utan", genres: [], imdbID: "tt0000005"))
    let ratings: [String: Any] = ["Response": "True", "imdbRating": "8.8",
                                  "Ratings": [["Source": "Rotten Tomatoes", "Value": "87%"]]]
    stub.on("omdb|tt1375666", StubResponse(body: try JSONSerialization.data(withJSONObject: ratings)))
    stub.on("omdb|tt0000005", StubResponse(status: 500))
    let omdb = OMDbClient(apiKey: "omdb-test-key", http: stub)
    let s = service(f, stub, omdb: omdb)

    let m = try #require(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1"))
    #expect(m.imdbRating == 8.8 && m.rottenTomatoes == 87)
    #expect(try f.store.metadata(kind: .movie, tmdbID: 27205)?.rottenTomatoes == 87)
    // OMDb-fel ignoreras.
    let other = try #require(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m2"))
    #expect(other.title == "Utan" && other.imdbRating == nil)
}

@Test func refreshListsUsesNamesAndTTL() async throws {
    let f = try metaFixture()
    let stub = TMDBStub()
    stub.on("/3/trending/movie/week", idsResponse([1, 2]))
    stub.on("/3/trending/tv/week", idsResponse([3]))
    stub.on("/3/movie/popular", idsResponse([4, 5]))
    stub.on("/3/tv/popular", idsResponse([6]))
    let clock = TestClock()
    let s = service(f, stub, clock: clock)

    await s.refreshLists()
    #expect(try f.store.list("trending.movie")?.ids == [1, 2])
    #expect(try f.store.list("trending.series")?.ids == [3])
    #expect(try f.store.list("popular.movie.SE")?.ids == [4, 5])
    #expect(try f.store.list("popular.series.SE")?.ids == [6])
    #expect(MetadataService.listNames == ["trending.movie", "trending.series", "popular.movie.SE", "popular.series.SE"])
    #expect(stub.requests.count == 4)

    clock.advance(11 * 3600)
    await s.refreshLists()
    #expect(stub.requests.count == 4)
    clock.advance(2 * 3600)
    stub.on("/3/trending/movie/week", idsResponse([9]))
    await s.refreshLists()
    #expect(stub.requests.count == 8)
    #expect(try f.store.list("trending.movie")?.ids == [9])
}

// MARK: - Samtidighet, pauser och komplettering

@Test func concurrentEnrichIsSingleFlight() async throws {
    let f = try metaFixture(movies: (1...3).map { (i: Int) in metaMovie("m\(i)", "Film \(i)", tmdb: i) })
    let stub = TMDBStub(delay: .milliseconds(30))
    for i in 1...3 { stub.on("/3/movie/\(i)", detailsResponse(i, title: "Film \(i)", genres: [])) }
    let s = service(f, stub)
    async let first = s.enrich(playlistID: metaPID)
    async let second = s.enrich(playlistID: metaPID)
    let (a, b) = await (first, second)
    #expect(a == 3 && b == 3)
    #expect(stub.requests.count == 3)
}

@Test func concurrentMetadataSharesOneRequest() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", tmdb: 27205)])
    let stub = TMDBStub(delay: .milliseconds(30))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]))
    let s = service(f, stub)
    async let a = s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")
    async let b = s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")
    async let c = s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")
    let results = await [a, b, c]
    #expect(results.allSatisfy { $0?.title == "Inception" })
    #expect(stub.count("/3/movie/27205") == 1)
}

@Test func concurrentRefreshListsIsSingleFlight() async throws {
    let f = try metaFixture()
    let stub = TMDBStub(delay: .milliseconds(20))
    stub.on("/3/trending/movie/week", idsResponse([1]))
    stub.on("/3/trending/tv/week", idsResponse([2]))
    stub.on("/3/movie/popular", idsResponse([3]))
    stub.on("/3/tv/popular", idsResponse([4]))
    let s = service(f, stub)
    async let a: Void = s.refreshLists()
    async let b: Void = s.refreshLists()
    _ = await (a, b)
    #expect(stub.requests.count == 4)
}

@Test func lazyMetadataHonoursRetryAfter() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Ett", tmdb: 1), metaMovie("m2", "Två", tmdb: 2)])
    try f.store.saveMetadata(sampleMetadata(2, title: "Två (gammal)"), now: metaT0 - 40 * day)
    let stub = TMDBStub()
    stub.on("/3/movie/1", StubResponse(status: 429, headers: ["Retry-After": "30"]))
    stub.on("/3/movie/2", detailsResponse(2, title: "Två", genres: []))
    stub.on("/3/trending/movie/week", idsResponse([1]))
    let clock = TestClock()
    let s = service(f, stub, clock: clock)

    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    // Under pausen: cache eller nil, inga anrop alls.
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m2")?.title == "Två (gammal)")
    await s.refreshLists()
    #expect(stub.requests == ["/3/movie/1"])
    clock.advance(31)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m2")?.title == "Två")
    #expect(stub.count("/3/movie/2") == 1)
}

@Test func retryAfterIsCappedAtSixtySeconds() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Ett", tmdb: 1)])
    let stub = TMDBStub()
    stub.on("/3/movie/1", StubResponse(status: 429, headers: ["Retry-After": "3600"]),
            detailsResponse(1, title: "Ett", genres: []))
    let clock = TestClock()
    let s = service(f, stub, clock: clock)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    clock.advance(59)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    #expect(stub.count("/3/movie/1") == 1)
    clock.advance(2)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Ett")
}

@Test func rateLimitPausesAllWorkers() async throws {
    // m1 är nyast och bearbetas först; dess 429 kommer direkt medan övriga anrop tar 20 ms.
    let movies = [metaMovie("m1", "Film 1", tmdb: 1, added: metaT0)]
        + (2...8).map { (i: Int) in metaMovie("m\(i)", "Film \(i)", tmdb: i, added: metaT0 - Double(i) * day) }
    let f = try metaFixture(movies: movies)
    let stub = TMDBStub(delay: .milliseconds(20))
    stub.on("/3/movie/1", StubResponse(status: 429, headers: ["Retry-After": "3"]),
            detailsResponse(1, title: "Film 1", genres: []))
    stub.delay("/3/movie/1", .zero)
    for i in 2...8 { stub.on("/3/movie/\(i)", detailsResponse(i, title: "Film \(i)", genres: [])) }
    let sleep = SleepRecorder()
    // Klockan står still, så varje anrop som börjar efter 429:an väntar först ut pausen (3 s): omförsöket
    // för m1 och m5–m8, som startar när m2–m4 är klara.
    #expect(await service(f, stub, sleep: sleep).enrich(playlistID: metaPID) == 8)
    #expect(sleep.durations.count >= 5)
    #expect(sleep.durations.allSatisfy { $0 == .seconds(3) })
    #expect(stub.count("/3/movie/1") == 2)
}

@Test func cancellingDuringPauseReturnsPromptly() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception")])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Inception", StubResponse(status: 429, headers: ["Retry-After": "30"]))
    // Riktig klocka och riktig sömn: utan avbrott skulle varje paus ta 30 s.
    let s = MetadataService(store: f.store, library: f.library, client: tmdb(stub))
    let task = Task { await s.enrich(playlistID: metaPID) }
    for _ in 0..<400 where stub.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(50))
    let started = ContinuousClock.now
    task.cancel()
    #expect(await task.value == 0)
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(stub.requests.count == 1)
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
}

@Test func enrichCompletesMatchedItemsWithoutMetadata() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception")])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 27205, confidence: 0.9,
                          now: metaT0)
    let stub = TMDBStub()
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]))
    let s = service(f, stub)
    #expect(await s.enrich(playlistID: metaPID) == 0)   // ingen ny matchning, bara komplettering
    #expect(stub.requests == ["/3/movie/27205"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 28, limit: 10).map(\.providerID) == ["m1"])
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1")?.confidence == 0.9)
    #expect(await s.enrich(playlistID: metaPID) == 0)
    #expect(stub.requests.count == 1)
}

@Test func cacheInOtherLanguageIsStale() async throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception", tmdb: 27205)])
    var english = sampleMetadata(27205, title: "Inception (en)")
    english.language = "en-US"
    try f.store.saveMetadata(english, now: metaT0)
    let stub = TMDBStub()
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception (sv)", genres: []))
    let s = service(f, stub)
    #expect(await s.metadata(playlistID: metaPID, kind: .movie, providerID: "m1")?.title == "Inception (sv)")
    #expect(try f.store.metadata(kind: .movie, tmdbID: 27205)?.language == "sv-SE")
}

@Test func batchWithoutHitsStillProgressesSoLaterBatchesRun() async throws {
    // De två nyaste saknar träff hos TMDB; de två äldre matchar. Första omgången (2 poster) får 0 träffar men
    // har gjort framsteg, så berikningen ska fortsätta och hitta de äldre i nästa omgång.
    let f = try metaFixture(movies: [
        metaMovie("m1", "Nothing Alpha", added: metaT0.addingTimeInterval(400)),
        metaMovie("m2", "Nothing Beta", added: metaT0.addingTimeInterval(300)),
        metaMovie("m3", "Inception", added: metaT0.addingTimeInterval(200)),
        metaMovie("m4", "Arrival", added: metaT0.addingTimeInterval(100)),
    ])
    let stub = TMDBStub()
    stub.on("/3/search/movie|Nothing Alpha", searchResponse([]))
    stub.on("/3/search/movie|Nothing Beta", searchResponse([]))
    stub.on("/3/search/movie|Inception", searchResponse([(27205, "Inception", "2010-07-15")]))
    stub.on("/3/search/movie|Arrival", searchResponse([(329865, "Arrival", "2016-11-10")]))
    stub.on("/3/movie/27205", detailsResponse(27205, title: "Inception", genres: [28]))
    stub.on("/3/movie/329865", detailsResponse(329865, title: "Arrival", genres: [18]))
    let s = service(f, stub)

    let first = await s.enrichBatch(playlistID: metaPID, batch: 2)
    #expect(first == EnrichOutcome(workItems: 2, matched: 0, progressed: 2, interrupted: false))
    #expect(first.shouldContinue)
    let second = await s.enrichBatch(playlistID: metaPID, batch: 2)
    #expect(second.matched == 2)
    #expect(second.shouldContinue)
    let third = await s.enrichBatch(playlistID: metaPID, batch: 2)
    #expect(third == EnrichOutcome())
    #expect(!third.shouldContinue)
}

@Test func seasonEpisodesAreMatchedFetchedAndCachedForTheSession() async throws {
    let f = try metaFixture(movies: [], series: [metaSeries("s1", "Bron")])
    let stub = TMDBStub()
    stub.on("/3/search/tv|Bron", searchResponse([(45016, "Bron", "2011-09-21")], series: true))
    stub.on("/3/tv/45016", detailsResponse(45016, title: "Bron", genres: [80], series: true))
    let season = #"{"episodes":[{"episode_number":1,"name":"Brottsplatsen","overview":"Ett lik hittas.","runtime":58,"still_path":"/a.jpg"}]}"#
    stub.on("/3/tv/45016/season/1", StubResponse(body: Data(season.utf8)))
    let s = service(f, stub)

    let first = await s.episodes(playlistID: metaPID, providerID: "s1", season: 1)
    #expect(first[1]?.name == "Brottsplatsen" && first[1]?.runtimeMinutes == 58)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .series, providerID: "s1") == 45016)   // matchades först
    let second = await s.episodes(playlistID: metaPID, providerID: "s1", season: 1)
    #expect(second == first)
    #expect(stub.count("/3/tv/45016/season/1") == 1)
}

@Test func seasonEpisodesAreEmptyWithoutClient() async throws {
    let f = try metaFixture(movies: [], series: [metaSeries("s1", "Bron")])
    let s = service(f, nil)
    #expect(await s.episodes(playlistID: metaPID, providerID: "s1", season: 1).isEmpty)
}
