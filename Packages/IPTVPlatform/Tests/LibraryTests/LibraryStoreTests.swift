import Core
import Foundation
import GRDB
import Providers
import Testing

@testable import Library

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let t1 = Date(timeIntervalSince1970: 2_000_000)
private let t2 = Date(timeIntervalSince1970: 3_000_000)
private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func playlist() -> Playlist {
    Playlist(id: pid, name: "Test", kind: .xtream, createdAt: t0)
}

private func movie(_ id: String, title: String? = nil, category: String? = nil) -> Movie {
    Movie(providerID: id, title: title ?? "Movie \(id)", year: 2020, categoryID: category,
          posterURL: URL(string: "http://img.example/\(id).jpg"), container: "mp4",
          locator: .xtream(kind: .movie, streamID: id, container: "mp4"))
}

private func live(_ id: String, name: String, category: String? = nil) -> LiveStream {
    LiveStream(providerID: id, name: name, categoryID: category,
               locator: .xtream(kind: .live, streamID: id, container: "ts"))
}

private func catalog(movies ids: [String]) -> ProviderCatalog {
    ProviderCatalog(movies: ids.map { movie($0) })
}

private func brokenCatalog() -> ProviderCatalog {
    ProviderCatalog(movies: [movie("5"), movie("")])
}

private func storeWith(movies titles: [String] = [], live names: [String] = []) throws -> LibraryStore {
    let s = try LibraryStore(db: .inMemory())
    try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        movies: titles.enumerated().map { movie("m\($0.offset)", title: $0.element) },
        live: names.enumerated().map { live("l\($0.offset)", name: $0.element) })
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    return s
}

private func firstSeen(_ s: LibraryStore, _ id: String) throws -> Date? {
    try s.db.writer.read { db in
        try Double.fetchOne(db, sql: "SELECT firstSeenAt FROM movie WHERE providerID = ?", arguments: [id])
            .map { Date(timeIntervalSince1970: $0) }
    }
}

private func dumpAllText(_ db: AppDatabase) throws -> String {
    try db.writer.read { db in
        var out = ""
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for table in tables {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") {
                for (_, value) in row {
                    switch value.storage {
                    case let .string(s): out += s + "\n"
                    case let .blob(d): out += (String(data: d, encoding: .utf8) ?? "") + "\n"
                    default: out += "\(value)\n"
                    }
                }
            }
        }
        return out
    }
}

@Test func replaceIsIdempotentAndKeepsFirstSeen() throws {
    let s = try LibraryStore(db: .inMemory()); let p = playlist(); try s.upsertPlaylist(p)
    try s.replaceCatalog(catalog(movies: ["1", "2"]), playlistID: p.id, now: t0)
    try s.replaceCatalog(catalog(movies: ["1", "2", "3"]), playlistID: p.id, now: t1)
    #expect(try s.counts(playlistID: p.id)[.movie] == 3)
    #expect(try firstSeen(s, "1") == t0)
    #expect(try firstSeen(s, "3") == t1)
    try s.replaceCatalog(catalog(movies: ["3"]), playlistID: p.id, now: t2)
    #expect(try s.counts(playlistID: p.id)[.movie] == 1)
}

@Test func reimportWithSameTimestampStillRemovesStale() throws {
    let s = try LibraryStore(db: .inMemory()); let p = playlist(); try s.upsertPlaylist(p)
    try s.replaceCatalog(catalog(movies: ["1", "2"]), playlistID: p.id, now: t0)
    try s.replaceCatalog(catalog(movies: ["1"]), playlistID: p.id, now: t0)
    #expect(try s.counts(playlistID: p.id)[.movie] == 1)
}

@Test func failedReplaceLeavesOldCatalog() throws {
    let s = try LibraryStore(db: .inMemory()); let p = playlist(); try s.upsertPlaylist(p)
    try s.replaceCatalog(catalog(movies: ["1"]), playlistID: p.id, now: t0)
    #expect(throws: (any Error).self) { try s.replaceCatalog(brokenCatalog(), playlistID: p.id, now: t1) }
    #expect(try s.counts(playlistID: p.id)[.movie] == 1)
    #expect(try s.search("Movie", playlistID: p.id, limit: 10).map(\.providerID) == ["1"])
}

@Test func duplicateProviderIDsDoNotFail() throws {
    let s = try LibraryStore(db: .inMemory()); let p = playlist(); try s.upsertPlaylist(p)
    let c = ProviderCatalog(
        movies: [movie("1", title: "First"), movie("1", title: "Second")],
        live: [live("9", name: "A"), live("9", name: "A")])
    try s.replaceCatalog(c, playlistID: p.id, now: t0)
    let counts = try s.counts(playlistID: p.id)
    #expect(counts[.movie] == 1)
    #expect(counts[.live] == 1)
    #expect(try s.items(playlistID: p.id, kind: .movie, categoryID: nil, limit: 10, offset: 0).map(\.title) == ["Second"])
    #expect(try s.search("Second", playlistID: p.id, limit: 10).count == 1)
    #expect(try s.search("First", playlistID: p.id, limit: 10).isEmpty)
}

@Test func searchIsDiacriticAndPrefixInsensitive() throws {
    let s = try storeWith(movies: ["Mamma Mia!", "Fröken Julie", "Dune: Part Two"])
    #expect(try s.search("froken", playlistID: pid, limit: 10).map(\.title) == ["Fröken Julie"])
    #expect(try s.search("du", playlistID: pid, limit: 10).map(\.title) == ["Dune: Part Two"])
    #expect(try s.search("part tw", playlistID: pid, limit: 10).map(\.title) == ["Dune: Part Two"])
    #expect(try s.search("\"; DROP", playlistID: pid, limit: 10).isEmpty)
    #expect(try s.search("", playlistID: pid, limit: 10).isEmpty)
    #expect(try s.search("* \" ( ) NEAR AND", playlistID: pid, limit: 10).isEmpty)
}

@Test func searchCoversMoviesSeriesAndLive() throws {
    let s = try LibraryStore(db: .inMemory()); try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        movies: [movie("1", title: "Alpha Movie")],
        series: [Series(providerID: "s1", title: "Alpha Series", year: 2019)],
        live: [live("l1", name: "Alpha TV")])
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    let hits = try s.search("alpha", playlistID: pid, limit: 10)
    #expect(Set(hits.map(\.id)) == ["movie:1", "series:s1", "live:l1"])
    #expect(hits.first { $0.kind == .series }?.year == 2019)
    #expect(hits.first { $0.kind == .movie }?.posterURL == URL(string: "http://img.example/1.jpg"))
}

@Test func searchFiltersByKindBeforeLimit() throws {
    let s = try LibraryStore(db: .inMemory()); try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        movies: (1...5).map { movie("m\($0)", title: "Alpha Movie \($0)") },
        series: [Series(providerID: "s1", title: "Alpha Series", year: 2019)],
        live: [live("l1", name: "Alpha")])
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    // Utan typfilter fyller filmerna och live-kanalen gränsen; serien får ändå plats med filtret.
    #expect(try s.search("alpha", playlistID: pid, kind: .series, limit: 2).map(\.id) == ["series:s1"])
    #expect(try s.search("alpha", playlistID: pid, kind: .live, limit: 2).map(\.id) == ["live:l1"])
    let movies = try s.search("alpha", playlistID: pid, kind: .movie, limit: 3)
    #expect(movies.count == 3 && movies.allSatisfy { $0.kind == .movie })
    #expect(try s.search("alpha", playlistID: pid, limit: 10).count == 7)
}

@Test func searchIsScopedToPlaylistAndRemovedWithIt() throws {
    let s = try storeWith(movies: ["Dune"])
    let other = UUID()
    try s.upsertPlaylist(Playlist(id: other, name: "Other", kind: .m3u, createdAt: t0))
    #expect(try s.search("dune", playlistID: other, limit: 10).isEmpty)
    try s.deletePlaylist(pid)
    #expect(try s.search("dune", playlistID: pid, limit: 10).isEmpty)
    #expect(try s.playlists().map(\.id) == [other])
    #expect(try s.counts(playlistID: pid)[.movie] == 0)
}

@Test func channelGroupsComeFromLiveStreams() throws {
    let s = try storeWith(live: ["SE: TV4 HD", "SE: TV4 FHD", "SE: SVT1 HD"])
    #expect(try s.channelGroups(playlistID: pid).count == 2)
}

@Test func itemsAndCategoriesFilterByKindAndCategory() throws {
    let s = try LibraryStore(db: .inMemory()); try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        categories: [
            Core.Category(providerID: "1", name: "Action", kind: .movie, sortIndex: 1),
            Core.Category(providerID: "1", name: "News", kind: .live, sortIndex: 0),
            Core.Category(providerID: "2", name: "Drama", kind: .movie, sortIndex: 0),
        ],
        movies: [movie("a", title: "B", category: "1"), movie("b", title: "A", category: "1"), movie("c", title: "C", category: "2")],
        live: [live("x", name: "Chan", category: "1")])
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    #expect(try s.categories(playlistID: pid, kind: .movie).map(\.name) == ["Drama", "Action"])
    #expect(try s.categories(playlistID: pid, kind: .live).map(\.name) == ["News"])
    #expect(try s.items(playlistID: pid, kind: .movie, categoryID: "1", limit: 10, offset: 0).map(\.title) == ["A", "B"])
    #expect(try s.items(playlistID: pid, kind: .movie, categoryID: nil, limit: 2, offset: 1).map(\.title) == ["B", "C"])
    #expect(try s.items(playlistID: pid, kind: .live, categoryID: nil, limit: 10, offset: 0).map(\.id) == ["live:x"])
}

@Test func playlistsRoundTrip() throws {
    let s = try LibraryStore(db: .inMemory())
    var p = playlist()
    try s.upsertPlaylist(p)
    p.name = "Renamed"
    try s.upsertPlaylist(p)
    #expect(try s.playlists() == [p])
    try s.replaceCatalog(catalog(movies: ["1"]), playlistID: p.id, now: t1)
    #expect(try s.playlists().first?.lastImportedAt == t1)
}

private let fixtureM3U = """
#EXTM3U
#EXTINF:-1 tvg-id="a" group-title="Movies",Movie A (2020)
http://srv.example:8080/movie/myUser/s3cr3t/101.mkv
#EXTINF:-1 group-title="Live",Chan One
http://srv.example:8080/live/myUser/s3cr3t/55.ts
#EXTINF:-1 group-title="Live",Chan Two
http://cdn.example/stream/abc/index.m3u8?user=myUser&token=s3cr3t
#EXTINF:-1 group-title="Live",Chan Three
http://cdn.example/myUser/s3cr3t/three.m3u8
#EXTINF:-1 group-title="Series",Some Show S01E02
http://srv.example:8080/series/myUser/s3cr3t/700.mkv
"""

@Test func databaseContainsNoCredentials() throws {
    let s = try LibraryStore(db: .inMemory()); let p = playlist(); try s.upsertPlaylist(p)
    let secret = PlaylistSecret.m3u(
        url: URL(string: "http://srv.example:8080/get.php?username=myUser&password=s3cr3t&type=m3u")!, epgURL: nil)
    let cat = M3UMapper.catalog(from: M3UParser.parse(fixtureM3U), secret: secret)
    try s.replaceCatalog(cat, playlistID: p.id, now: t0)
    #expect(try s.counts(playlistID: p.id)[.live] == 3)
    let dump = try dumpAllText(s.db)
    #expect(dump.contains("Chan Two"))   // dumpen är inte tom
    #expect(dump.contains("myUser") == false)
    #expect(dump.contains("s3cr3t") == false)
}

@Test func streamLocatorStoredShapeIsPinned() throws {
    let decoder = JSONDecoder()
    let xt = try decoder.decode(
        StreamLocator.self,
        from: Data(#"{"xtream":{"kind":"movie","streamID":"42","container":"mkv"}}"#.utf8))
    #expect(xt == .xtream(kind: .movie, streamID: "42", container: "mkv"))
    let tpl = try decoder.decode(
        StreamLocator.self, from: Data(#"{"template":{"_0":"{server}/x/{username}/{password}"}}"#.utf8))
    #expect(tpl == .template("{server}/x/{username}/{password}"))

    // Det som faktiskt ligger i databasen ska ha samma form.
    let s = try LibraryStore(db: .inMemory()); try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        movies: [Movie(providerID: "1", title: "T", locator: .xtream(kind: .movie, streamID: "42", container: "mkv"))],
        live: [live("2", name: "L")])
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    let stored = try s.db.writer.read { db in
        try String.fetchOne(db, sql: "SELECT locator FROM movie WHERE providerID = '1'")
    }
    let obj = try JSONSerialization.jsonObject(with: Data(stored!.utf8)) as? [String: Any]
    let inner = obj?["xtream"] as? [String: String]
    #expect(inner == ["kind": "movie", "streamID": "42", "container": "mkv"])
}

@Test func searchRanksPrefixTitlesFirst() throws {
    let s = try LibraryStore(db: .inMemory()); try s.upsertPlaylist(playlist())
    let c = ProviderCatalog(
        movies: (0..<200).map { movie("m\($0)", title: "The X \($0)") },
        series: [Series(providerID: "s1", title: "Thelma")])
    try s.replaceCatalog(c, playlistID: pid, now: t0)
    #expect(try s.search("thel", playlistID: pid, limit: 5).first?.title == "Thelma")
    let the = try s.search("the", playlistID: pid, limit: 5)
    #expect(the.first?.title == "Thelma")
    #expect(the.count == 5)
    #expect(the.first?.kind == .series)
}

@Test func searchRanksExactBeforeLongerBeforeInfix() throws {
    let s = try storeWith(movies: ["Children of Dune", "Dune: Part Two", "Dune"])
    #expect(try s.search("dune", playlistID: pid, limit: 10).map(\.title)
            == ["Dune", "Dune: Part Two", "Children of Dune"])
}

@Test func upsertPlaylistKeepsCreatedAtAndLastImported() throws {
    let s = try LibraryStore(db: .inMemory())
    try s.upsertPlaylist(playlist())
    try s.replaceCatalog(catalog(movies: ["1"]), playlistID: pid, now: t1)
    var stale = playlist()
    stale.name = "Renamed"
    stale.createdAt = t2
    stale.lastImportedAt = nil
    try s.upsertPlaylist(stale)
    let p = try #require(try s.playlists().first)
    #expect(p.name == "Renamed")
    #expect(p.createdAt == t0)
    #expect(p.lastImportedAt == t1)
    stale.lastImportedAt = t2
    try s.upsertPlaylist(stale)
    #expect(try s.playlists().first?.lastImportedAt == t2)
}
