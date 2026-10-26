import Core
import Foundation
import GRDB
import Metadata
import Testing

@testable import Library

@Test func matchesSurviveCatalogRefresh() throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Inception")])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 27205, confidence: 0.9,
                          now: metaT0)
    try f.library.replaceCatalog(ProviderCatalog(movies: [metaMovie("m1", "Inception (ny titel)")]),
                                 playlistID: metaPID, now: metaT0 + day)
    let match = try #require(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1"))
    #expect(match.tmdbID == 27205 && match.confidence == 0.9 && match.attemptedAt == metaT0)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "m1") == 27205)
}

@Test func providerTMDBIDWins() throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Film", tmdb: 42), metaMovie("m2", "Annan")],
                            series: [metaSeries("s1", "Serie", tmdb: 7)])
    #expect(try f.store.match(playlistID: metaPID, kind: .movie, providerID: "m1") == nil)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "m1") == 42)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .series, providerID: "s1") == 7)
    // Även en avvikande matchrad förlorar mot leverantörens id.
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 99, confidence: 0.8, now: metaT0)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "m1") == 42)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "m2") == nil)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .movie, providerID: "saknas") == nil)
    #expect(try f.store.tmdbID(playlistID: metaPID, kind: .live, providerID: "m1") == nil)
}

@Test func genreQueryReturnsOnlyPlaylistItems() throws {
    let f = try metaFixture(
        movies: [metaMovie("m1", "Beta", tmdb: 1, poster: "http://img.invalid/b.jpg"), metaMovie("m2", "Alfa"),
                 metaMovie("m3", "Gamma", tmdb: 3)],
        otherMovies: [metaMovie("x1", "Annan lista", tmdb: 1)])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m2", tmdbID: 2, confidence: 0.9, now: metaT0)
    try f.store.saveMetadata(sampleMetadata(1, genres: [28, 878]), now: metaT0)
    try f.store.saveMetadata(sampleMetadata(2, genres: [28]), now: metaT0)
    try f.store.saveMetadata(sampleMetadata(3, genres: [18]), now: metaT0)
    // Samma id som serie räknas inte för filmer.
    try f.store.saveMetadata(sampleMetadata(3, kind: .series, genres: [28]), now: metaT0)

    let action = try f.store.items(playlistID: metaPID, kind: .movie, genreID: 28, limit: 10)
    #expect(action.map(\.providerID) == ["m2", "m1"])   // titelordning: Alfa, Beta
    #expect(action.last?.posterURL == URL(string: "http://img.invalid/b.jpg"))
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 28, limit: 1).map(\.providerID) == ["m2"])
    #expect(try f.store.items(playlistID: metaOtherPID, kind: .movie, genreID: 28, limit: 10).map(\.providerID) == ["x1"])
    #expect(try f.store.items(playlistID: metaPID, kind: .series, genreID: 28, limit: 10).isEmpty)

    // Genrer ersätts när metadatan sparas om.
    try f.store.saveMetadata(sampleMetadata(1, genres: [18]), now: metaT0 + day)
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 28, limit: 10).map(\.providerID) == ["m2"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 18, limit: 10).map(\.providerID) == ["m1", "m3"])
    let genreRows = try f.db.writer.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM titleGenre WHERE kind = 'movie' AND tmdbID = 1")
    }
    #expect(genreRows == 1)
}

@Test func tmdbIDListKeepsOrderAndFilters() throws {
    let f = try metaFixture(movies: [metaMovie("m3", "Tre", tmdb: 3), metaMovie("m5", "Fem"),
                                     metaMovie("m5b", "Fem (kopia)", tmdb: 5)],
                            otherMovies: [metaMovie("x9", "Nio", tmdb: 9)])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m5", tmdbID: 5, confidence: 0.9, now: metaT0)
    let items = try f.store.items(playlistID: metaPID, kind: .movie, tmdbIDs: [5, 3, 9, 5])
    #expect(items.map(\.providerID) == ["m5", "m3"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, tmdbIDs: []).isEmpty)
    #expect(try f.store.items(playlistID: metaPID, kind: .series, tmdbIDs: [5, 3]).isEmpty)
}

@Test func metadataRoundTripsWithFetchTime() throws {
    let f = try metaFixture()
    var m = sampleMetadata(27205, title: "Inception", genres: [28], imdbID: "tt1375666")
    m.imdbRating = 8.8
    m.rottenTomatoes = 87
    try f.store.saveMetadata(m, now: metaT0)
    #expect(try f.store.metadata(kind: .movie, tmdbID: 27205) == m)
    #expect(try f.store.cachedMetadata(kind: .movie, tmdbID: 27205)?.fetchedAt == metaT0)
    #expect(try f.store.metadata(kind: .series, tmdbID: 27205) == nil)
}

@Test func unmatchedItemsHonourRetryInterval() throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Ett", year: 2001), metaMovie("m2", "Två"),
                                     metaMovie("m3", "Tre"), metaMovie("m4", "Fyra", tmdb: 44)])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m2", tmdbID: 2, confidence: 0.9, now: metaT0)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m3", tmdbID: nil, confidence: 0.4, now: metaT0)

    let soon = try f.store.unmatchedItems(playlistID: metaPID, kind: .movie, limit: 10, now: metaT0 + 6 * day)
    #expect(Set(soon.map(\.providerID)) == ["m1", "m4"])
    #expect(soon.first { $0.providerID == "m1" }?.year == 2001)
    #expect(soon.first { $0.providerID == "m4" }?.providerTMDBID == 44)
    let later = try f.store.unmatchedItems(playlistID: metaPID, kind: .movie, limit: 10, now: metaT0 + 8 * day)
    #expect(Set(later.map(\.providerID)) == ["m1", "m3", "m4"])
    #expect(try f.store.unmatchedItems(playlistID: metaPID, kind: .movie, limit: 1, now: metaT0).count == 1)
    #expect(try f.store.unmatchedItems(playlistID: metaPID, kind: .live, limit: 10, now: metaT0).isEmpty)
}

@Test func listsRoundTrip() throws {
    let f = try metaFixture()
    #expect(try f.store.list("trending.movie") == nil)
    try f.store.saveList("trending.movie", ids: [3, 1, 2], now: metaT0)
    let list = try #require(try f.store.list("trending.movie"))
    #expect(list.ids == [3, 1, 2] && list.fetchedAt == metaT0)
    try f.store.saveList("trending.movie", ids: [9], now: metaT0 + 1)
    #expect(try f.store.list("trending.movie")?.ids == [9])
}

@Test func shelfQueriesPreferProviderIDOverMatch() throws {
    // m1: leverantörens id 1 men en (felaktig) matchrad med id 2 – bara id 1 räknas.
    let f = try metaFixture(movies: [metaMovie("m1", "Ett", tmdb: 1), metaMovie("m2", "Två")])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 2, confidence: 0.8, now: metaT0)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m2", tmdbID: 2, confidence: 0.9, now: metaT0)
    try f.store.saveMetadata(sampleMetadata(1, genres: [10]), now: metaT0)
    try f.store.saveMetadata(sampleMetadata(2, genres: [20]), now: metaT0)
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 10, limit: 10).map(\.providerID) == ["m1"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, genreID: 20, limit: 10).map(\.providerID) == ["m2"])
    #expect(try f.store.items(playlistID: metaPID, kind: .movie, tmdbIDs: [2, 1]).map(\.providerID) == ["m2", "m1"])
}

@Test func matchedWithoutMetadataFindsMissingDetails() throws {
    let f = try metaFixture(movies: [metaMovie("m1", "Ett"), metaMovie("m2", "Två"), metaMovie("m3", "Tre")])
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m1", tmdbID: 1, confidence: 0.9, now: metaT0)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m2", tmdbID: 2, confidence: 0.8, now: metaT0)
    try f.store.saveMatch(playlistID: metaPID, kind: .movie, providerID: "m3", tmdbID: nil, confidence: 0.3, now: metaT0)
    try f.store.saveMetadata(sampleMetadata(1), now: metaT0)
    let missing = try f.store.matchedWithoutMetadata(playlistID: metaPID, kind: .movie, limit: 10)
    #expect(missing.map(\.providerID) == ["m2"])
    #expect(missing.first?.tmdbID == 2 && missing.first?.confidence == 0.8 && missing.first?.title == "Två")
    #expect(try f.store.matchedWithoutMetadata(playlistID: metaPID, kind: .series, limit: 10).isEmpty)
}
