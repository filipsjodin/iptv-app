import Core
import Foundation
import GRDB
import Providers
import Testing

@testable import Library

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let t1 = Date(timeIntervalSince1970: 2_000_000)
private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

private func movie(_ id: String, tmdb: Int? = nil) -> Movie {
    Movie(providerID: id, title: "Movie \(id)", container: "mkv", tmdbID: tmdb,
          locator: .xtream(kind: .movie, streamID: id, container: "mkv"))
}

private func ep(_ id: String, series: String, season: Int = 1, number: Int = 1) -> Episode {
    Episode(providerID: id, seriesProviderID: series, season: season, number: number, title: "Ep \(id)",
            container: "mp4", locator: .xtream(kind: .series, streamID: id, container: "mp4"))
}

private func catalog(series ids: [String] = [], episodes: [Episode] = [], movies: [Movie] = [],
                     episodesComplete: Bool) -> ProviderCatalog {
    ProviderCatalog(movies: movies, series: ids.map { Series(providerID: $0, title: "Series \($0)") },
                    episodes: episodes, episodesComplete: episodesComplete)
}

private func makeStore(series: [String] = []) throws -> LibraryStore {
    let s = try LibraryStore(db: .inMemory())
    try s.upsertPlaylist(Playlist(id: pid, name: "T", kind: .xtream, createdAt: t0))
    try s.replaceCatalog(catalog(series: series, episodesComplete: false), playlistID: pid, now: t0)
    return s
}

private let noAccount = PlaylistAccountInfo(maxConnections: nil, expiresAt: nil, status: nil)

@Test func xtreamRefreshKeepsLazyEpisodes() throws {
    let s = try makeStore(series: ["s1", "s2"])
    try s.upsertEpisodes([ep("e1", series: "s1")], seriesProviderID: "s1", playlistID: pid, now: t0)
    try s.upsertEpisodes([ep("e2", series: "s2")], seriesProviderID: "s2", playlistID: pid, now: t0)
    try s.replaceCatalog(catalog(series: ["s1"], episodesComplete: false), playlistID: pid, now: t1)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["e1"])
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s2").isEmpty)
}

@Test func m3uRefreshReplacesEpisodes() throws {
    let s = try makeStore(series: ["s1"])
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e1", series: "s1"), ep("e2", series: "s1", number: 2)],
                                 episodesComplete: true), playlistID: pid, now: t0)
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e2", series: "s1", number: 2)],
                                 episodesComplete: true), playlistID: pid, now: t1)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["e2"])
}

@Test func incompleteCatalogWithEpisodesUpsertsThem() throws {
    let s = try makeStore(series: ["s1"])
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e9", series: "s1")], episodesComplete: false),
                         playlistID: pid, now: t1)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["e9"])
}

@Test func upsertEpisodesReplacesOnlyThatSeriesAndKeepsFirstSeen() throws {
    let s = try makeStore(series: ["s1", "s2"])
    try s.upsertEpisodes([ep("e1", series: "s1"), ep("e2", series: "s1", number: 2)],
                         seriesProviderID: "s1", playlistID: pid, now: t0)
    try s.upsertEpisodes([ep("x1", series: "s2")], seriesProviderID: "s2", playlistID: pid, now: t0)
    try s.upsertEpisodes([ep("e1", series: "s1")], seriesProviderID: "s1", playlistID: pid, now: t1)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["e1"])
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s2").map(\.providerID) == ["x1"])
    let first = try s.db.writer.read {
        try Double.fetchOne($0, sql: "SELECT firstSeenAt FROM episode WHERE providerID = 'e1'")
    }
    #expect(first == t0.timeIntervalSince1970)
}

@Test func episodesAreSortedBySeasonAndNumber() throws {
    let s = try makeStore(series: ["s1"])
    try s.upsertEpisodes([ep("c", series: "s1", season: 2, number: 1), ep("b", series: "s1", season: 1, number: 2),
                          ep("a", series: "s1", season: 1, number: 1)],
                         seriesProviderID: "s1", playlistID: pid, now: t0)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["a", "b", "c"])
}

@Test func tmdbIDSurvivesRefreshWithoutOne() throws {
    let s = try LibraryStore(db: .inMemory())
    try s.upsertPlaylist(Playlist(id: pid, name: "T", kind: .xtream, createdAt: t0))
    try s.replaceCatalog(
        ProviderCatalog(movies: [movie("1", tmdb: 42)], series: [Series(providerID: "s", title: "S", tmdbID: 7)]),
        playlistID: pid, now: t0)
    try s.replaceCatalog(
        ProviderCatalog(movies: [movie("1")], series: [Series(providerID: "s", title: "S")]),
        playlistID: pid, now: t1)
    #expect(try s.movie(playlistID: pid, providerID: "1")?.tmdbID == 42)
    #expect(try s.series(playlistID: pid, providerID: "s")?.tmdbID == 7)
}

@Test func locatorLookupForMovieAndEpisode() throws {
    let s = try makeStore(series: ["s1"])
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e1", series: "s1")], movies: [movie("1")],
                                 episodesComplete: true), playlistID: pid, now: t1)
    #expect(try s.locator(playlistID: pid, kind: .movie, providerID: "1")
            == .xtream(kind: .movie, streamID: "1", container: "mkv"))
    #expect(try s.locator(playlistID: pid, kind: .series, providerID: "e1") != nil)
    #expect(try s.locator(playlistID: pid, kind: .movie, providerID: "missing") == nil)
}

@Test func accountInfoRoundTripAndUnknown() throws {
    let s = try makeStore()
    #expect(try s.accountInfo(playlistID: pid) == noAccount)
    let info = PlaylistAccountInfo(maxConnections: 3, expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   status: "Active")
    try s.setAccountInfo(info, playlistID: pid)
    #expect(try s.accountInfo(playlistID: pid) == info)
    #expect(try s.accountInfo(playlistID: UUID()) == noAccount)
}

@Test func v2AddsIndexes() throws {
    let s = try makeStore()
    let names = try s.db.writer.read {
        try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
    }
    #expect(names.contains("movie_title") && names.contains("series_title"))
}

@Test func formatSummaryCountsStoredContainers() throws {
    let s = try makeStore(series: ["s1"])
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [], movies: [movie("m1"), movie("m2")],
                                 episodesComplete: false), playlistID: pid, now: t1)
    try s.upsertEpisodes([ep("e1", series: "s1")], seriesProviderID: "s1", playlistID: pid, now: t1)
    let summary = try s.formatSummary(playlistID: pid)
    #expect(summary.containersByKind[.movie] == ["mkv": 2])
    #expect(summary.containersByKind[.series] == ["mp4": 1])
    #expect(summary.totals == [.movie: 2, .series: 1, .live: 0])
}

@Test func episodeDetailsRoundTrip() throws {
    let s = try makeStore(series: ["s1"])
    var e = ep("e1", series: "s1")
    e.stillURL = URL(string: "https://img.example.invalid/e1.jpg")
    e.overview = "En handling."
    e.durationSeconds = 2520
    try s.upsertEpisodes([e, ep("e2", series: "s1", number: 2)], seriesProviderID: "s1", playlistID: pid, now: t0)
    let read = try s.episodes(playlistID: pid, seriesProviderID: "s1")
    #expect(read[0].stillURL == e.stillURL)
    #expect(read[0].overview == "En handling.")
    #expect(read[0].durationSeconds == 2520)
    #expect(read[1].stillURL == nil && read[1].overview == nil && read[1].durationSeconds == nil)
}

@Test func catalogEpisodesRoundTripDetails() throws {
    let s = try makeStore()
    var e = ep("e1", series: "s1")
    e.durationSeconds = 600
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [e], episodesComplete: true), playlistID: pid, now: t1)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").first?.durationSeconds == 600)
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1") == false)
}

/// Raden räknas som omhämtad först när en hämtning skrivit den; en tom omhämtning kan markera utan att radera.
@Test func episodesNeedDetailsUntilFetchedOnce() throws {
    let s = try makeStore(series: ["s1"])
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1") == false)  // inga avsnitt
    try s.upsertEpisodes([ep("old", series: "s1")], seriesProviderID: "s1", playlistID: pid, now: t0)
    // Efterliknar en rad som lagrats före migreringen.
    try s.db.writer.write { db in try db.execute(sql: "UPDATE episode SET detailsFetched = 0") }
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1"))
    try s.markEpisodeDetailsFetched(playlistID: pid, seriesProviderID: "s1")
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1") == false)
    #expect(try s.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["old"])

    try s.db.writer.write { db in try db.execute(sql: "UPDATE episode SET detailsFetched = 0") }
    try s.upsertEpisodes([ep("old", series: "s1")], seriesProviderID: "s1", playlistID: pid, now: t1)
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1") == false)
}

/// En katalograd utan uppgifter (M3U) skriver inte över lagrade uppgifter och markerar inte avsnittet som omhämtat.
@Test func catalogUpsertDoesNotWipeStoredDetails() throws {
    let s = try makeStore(series: ["s1"])
    var detailed = ep("e1", series: "s1")
    detailed.stillURL = URL(string: "https://img.example.invalid/e1.jpg")
    detailed.overview = "Handling."
    detailed.durationSeconds = 900
    try s.upsertEpisodes([detailed], seriesProviderID: "s1", playlistID: pid, now: t0)
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e1", series: "s1")], episodesComplete: true),
                         playlistID: pid, now: t1)
    let read = try #require(try s.episodes(playlistID: pid, seriesProviderID: "s1").first)
    #expect(read.stillURL == detailed.stillURL && read.overview == "Handling." && read.durationSeconds == 900)
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1") == false)

    // Ett nytt avsnitt utan uppgifter räknas som ännu inte omhämtat.
    try s.replaceCatalog(catalog(series: ["s1"], episodes: [ep("e2", series: "s1", number: 2)],
                                 episodesComplete: true), playlistID: pid, now: t1)
    #expect(try s.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1"))
}
