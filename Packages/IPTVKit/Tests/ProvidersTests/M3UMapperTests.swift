import Testing
import Foundation
import Core
@testable import Providers

@Test func classifiesByPathThenGroup() {
    func e(_ url: String, _ group: String = "") -> M3UEntry { .init(title: "x", duration: -1, attributes: ["group-title": group], url: url) }
    #expect(M3UMapper.kind(of: e("http://h/movie/u/p/1.mkv")) == .movie)
    #expect(M3UMapper.kind(of: e("http://h/series/u/p/2.mp4")) == .series)
    #expect(M3UMapper.kind(of: e("http://h/u/p/3")) == .live)
    #expect(M3UMapper.kind(of: e("http://h/x/4.mkv", "VOD | Action")) == .movie)
    #expect(M3UMapper.kind(of: e("http://h/x/5.mp4", "SERIES | Drama")) == .series)
}
@Test func parsesSeasonEpisodePatterns() {
    #expect(SeriesEpisodeParser.parse("Severance S02E04")! == ("Severance", 2, 4))
    #expect(SeriesEpisodeParser.parse("SE - Bron (2011) S1 E10")! == ("SE - Bron (2011)", 1, 10))
    #expect(SeriesEpisodeParser.parse("The Office 3x07")! == ("The Office", 3, 7))
    #expect(SeriesEpisodeParser.parse("Dune Part Two") == nil)
}
@Test func xtreamStyleUrlsBecomeLocatorsWithoutCredentials() {
    let secret = PlaylistSecret.m3u(url: URL(string: "http://h:80/get.php?username=u1&password=p1&type=m3u_plus")!, epgURL: nil)
    #expect(M3UMapper.locator(for: "http://h:80/movie/u1/p1/42.mkv", secret: secret) == .xtream(kind: .movie, streamID: "42", container: "mkv"))
    #expect(M3UMapper.locator(for: "http://h:80/u1/p1/9", secret: secret) == .xtream(kind: .live, streamID: "9", container: "ts"))
    #expect(M3UMapper.locator(for: "http://cdn/x.m3u8?token=p1", secret: secret) == .template("http://cdn/x.m3u8?token={password}"))
}
@Test func serverPrefixBecomesPlaceholder() {
    let secret = PlaylistSecret.m3u(url: URL(string: "http://h:80/get.php?username=u1&password=p1")!, epgURL: nil)
    #expect(M3UMapper.locator(for: "http://h:80/play/u1/x/9.m3u8", secret: secret) == .template("{server}/play/{username}/x/9.m3u8"))
}
@Test func fixtureMapsToCatalogAndGroupsEpisodes() throws {
    let c = M3UMapper.catalog(from: M3UParser.parse(try fixture("sample.m3u")), secret: .m3u(url: URL(string: "http://h/get.php?username=REDACTED&password=REDACTED")!, epgURL: nil))
    #expect(!c.movies.isEmpty && !c.live.isEmpty && !c.series.isEmpty)
    #expect(Set(c.episodes.map(\.seriesProviderID)).isSubset(of: Set(c.series.map(\.providerID))))
    #expect(c.series.count == 3)
    #expect(c.episodes.count == 15)
    #expect(Set(c.live.map(\.providerID)).count == c.live.count)
    #expect(Set(c.movies.map(\.providerID)).count == c.movies.count)
}
@Test func providerIDsAreStable() {
    // FNV-1a 64 av "a" är af63dc4c8601ec8c
    #expect(M3UMapper.fnv1a64Hex("a") == "af63dc4c8601ec8c")
}
