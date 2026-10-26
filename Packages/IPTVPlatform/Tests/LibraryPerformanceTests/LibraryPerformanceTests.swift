import Core
import Foundation
import Testing

@testable import Library

private func generatedCatalog(movies: Int, series: Int, episodes: Int, live: Int) -> ProviderCatalog {
    let words = ["the", "star", "wars", "dune", "fröken", "julie", "night", "river", "king", "last", "dark", "city", "x", "war"]
    func title(_ i: Int) -> String {
        "\(words[i % words.count].capitalized) \(words[(i / 7) % words.count]) \(words[(i / 31) % words.count]) \(i)"
    }
    var c = ProviderCatalog()
    c.movies.reserveCapacity(movies)
    for i in 0..<movies {
        c.movies.append(Movie(providerID: "m\(i)", title: title(i), year: 1950 + i % 75, categoryID: "\(i % 50)",
                              posterURL: URL(string: "http://img.example/m\(i).jpg"), container: "mp4",
                              locator: .xtream(kind: .movie, streamID: "m\(i)", container: "mp4")))
    }
    for i in 0..<series {
        c.series.append(Series(providerID: "s\(i)", title: title(i + 3), year: 1980 + i % 45, categoryID: "\(i % 20)"))
    }
    for i in 0..<episodes {
        c.episodes.append(Episode(providerID: "e\(i)", seriesProviderID: "s\(i % max(series, 1))", season: 1, number: i,
                                  title: "Ep \(i)", locator: .xtream(kind: .series, streamID: "e\(i)", container: "mkv")))
    }
    for i in 0..<live {
        c.live.append(LiveStream(providerID: "l\(i)", name: "SE: \(title(i + 5)) HD", categoryID: "\(i % 30)",
                                 locator: .xtream(kind: .live, streamID: "l\(i)", container: "ts")))
    }
    return c
}

@Test func import200kAndSearchFast() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = try LibraryStore(db: .onDisk(at: url))
    let p = Playlist(name: "Perf", kind: .xtream)
    try s.upsertPlaylist(p)
    let c = generatedCatalog(movies: 120_000, series: 20_000, episodes: 0, live: 60_000)
    let importTime = try ContinuousClock().measure { try s.replaceCatalog(c, playlistID: p.id, now: .now) }
    print("PERF import 200k: \(importTime)")
    #expect(importTime < .seconds(20))
    let refreshTime = try ContinuousClock().measure { try s.replaceCatalog(c, playlistID: p.id, now: .now) }
    print("PERF refresh 200k: \(refreshTime)")
    #expect(refreshTime < .seconds(20))
    for q in ["the", "star wa", "fröken", "x"] {
        var hits = 0
        let t = try ContinuousClock().measure { hits = try s.search(q, playlistID: p.id, limit: 50).count }
        print("PERF search '\(q)': \(t) (\(hits) hits)")
        #expect(hits > 0)
        #expect(t < .milliseconds(100))
    }
}

/// Hyllfrågor mot TMDB-data i en spellista med 120 000 filmer: hälften har leverantörens id, hälften en matchning.
@Test func metadataShelvesFastAt120k() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-meta-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase.onDisk(at: url)
    let library = LibraryStore(db: db)
    let store = MetadataStore(db: db)
    let p = Playlist(name: "Perf", kind: .xtream)
    try library.upsertPlaylist(p)
    var c = generatedCatalog(movies: 120_000, series: 0, episodes: 0, live: 0)
    for i in stride(from: 0, to: c.movies.count, by: 2) { c.movies[i].tmdbID = i + 1 }
    try library.replaceCatalog(c, playlistID: p.id, now: .now)

    try db.writer.write { db in
        let match = try db.makeStatement(sql: """
            INSERT INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
            VALUES (?, 'movie', ?, ?, 0.9, 0)
            """)
        let genre = try db.makeStatement(sql: "INSERT INTO titleGenre (kind, tmdbID, genreID) VALUES ('movie', ?, ?)")
        for i in 0..<120_000 {
            if i % 2 == 1 { try match.execute(arguments: [p.id.uuidString, "m\(i)", i + 1]) }
            try genre.execute(arguments: [i + 1, 1])                  // vanlig genre
            if i % 1000 == 0 || i % 1000 == 1 { try genre.execute(arguments: [i + 1, 99]) }   // sällsynt genre
        }
    }

    var shelf: [LibraryItem] = []
    let shelfTime = try ContinuousClock().measure {
        shelf = try store.items(playlistID: p.id, kind: .movie, genreID: 99, limit: 50)
    }
    print("PERF rare-genre shelf 120k: \(shelfTime) (\(shelf.count) items)")
    #expect(shelf.count == 50)
    #expect(shelfTime < .milliseconds(100))

    let ids = (0..<20).map { $0 * 5_999 + 1 }
    var list: [LibraryItem] = []
    let listTime = try ContinuousClock().measure {
        list = try store.items(playlistID: p.id, kind: .movie, tmdbIDs: ids)
    }
    print("PERF 20-id list 120k: \(listTime) (\(list.count) items)")
    #expect(list.map(\.providerID) == ids.map { "m\($0 - 1)" })
    #expect(listTime < .milliseconds(100))
}
