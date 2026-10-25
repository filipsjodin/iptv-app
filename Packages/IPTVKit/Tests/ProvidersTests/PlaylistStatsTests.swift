import Testing
import Foundation
import Core
@testable import Providers

func catalogWith(movies: [String] = [], live: [String] = [], episodes: [String] = []) -> ProviderCatalog {
    var c = ProviderCatalog()
    for (i, ext) in movies.enumerated() {
        c.movies.append(Movie(providerID: "m\(i)", title: "M\(i)", container: ext, locator: .xtream(kind: .movie, streamID: "\(i)", container: ext)))
    }
    for (i, ext) in live.enumerated() {
        c.live.append(LiveStream(providerID: "l\(i)", name: "L\(i)", locator: .xtream(kind: .live, streamID: "\(i)", container: ext)))
    }
    for (i, ext) in episodes.enumerated() {
        c.episodes.append(Episode(providerID: "e\(i)", seriesProviderID: "s", season: 1, number: i + 1, title: "E\(i)", container: ext,
                                  locator: .xtream(kind: .series, streamID: "\(i)", container: ext)))
    }
    return c
}

@Test func summarizesContainers() {
    let s = PlaylistStats.summarize(catalogWith(movies: ["mkv", "mkv", "mp4"], live: ["m3u8"]))
    #expect(s.containersByKind[.movie] == ["mkv": 2, "mp4": 1]); #expect(s.totals[.live] == 1)
}

@Test func summarizesEpisodesAndTemplateLocators() {
    var c = catalogWith(episodes: ["mp4", "mkv", "mp4"])
    c.live.append(LiveStream(providerID: "t", name: "T", locator: .template("{server}/play/{username}/9.m3u8?token={password}")))
    c.live.append(LiveStream(providerID: "u", name: "U", locator: .template("{server}/{username}/{password}/9")))
    let s = PlaylistStats.summarize(c)
    #expect(s.containersByKind[.series] == ["mp4": 2, "mkv": 1])
    #expect(s.containersByKind[.live] == ["m3u8": 1, "unknown": 1])
    #expect(s.totals[.movie] == 0)
}
