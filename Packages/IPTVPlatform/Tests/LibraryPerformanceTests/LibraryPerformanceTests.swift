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
    for q in ["the", "star wa", "fröken", "x"] {
        var hits = 0
        let t = try ContinuousClock().measure { hits = try s.search(q, playlistID: p.id, limit: 50).count }
        print("PERF search '\(q)': \(t) (\(hits) hits)")
        #expect(hits > 0)
        #expect(t < .milliseconds(100))
    }
}
