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

private func m3uSecret(_ u: String, _ p: String) -> PlaylistSecret {
    .m3u(url: URL(string: "http://h/get.php?username=\(u)&password=\(p)")!, epgURL: nil)
}

@Test func shortCredentialOnlyReplacesWholeSegments() {
    let l = M3UMapper.locator(for: "http://cdn.example.invalid/play/1/x/100.m3u8", secret: m3uSecret("1", "pw"))
    #expect(l == .template("http://cdn.example.invalid/play/{username}/x/100.m3u8"))
}
@Test func placeholdersAreNotCorrupted() {
    let l = M3UMapper.locator(for: "http://cdn.example.invalid/play/username/name/1.m3u8?a=name&b=username", secret: m3uSecret("username", "name"))
    #expect(l == .template("http://cdn.example.invalid/play/{username}/{password}/1.m3u8?a={password}&b={username}"))
}
@Test func percentEncodedCredentialInQueryValue() {
    let l = M3UMapper.locator(for: "http://cdn.example.invalid/x.m3u8?token=p%40ss%20w", secret: m3uSecret("u", "p%40ss%20w"))
    #expect(l == .template("http://cdn.example.invalid/x.m3u8?token={password}"))
}
@Test func serverPrefixMatchIsCaseInsensitive() {
    let l = M3UMapper.locator(for: "HTTP://H/play/u1/x.m3u8", secret: m3uSecret("u1", "p1"))
    #expect(l == .template("{server}/play/{username}/x.m3u8"))
}
@Test func catalogNeverContainsRawCredentials() {
    let user = "secretuser", pass = "secretpass"
    let text = """
    #EXTM3U
    #EXTINF:-1 group-title="A",Chan
    http://cdn.example.invalid/play/secretuser/secretpass/1.m3u8
    #EXTINF:-1 group-title="VOD",Film
    http://cdn.example.invalid/f.mkv?u=secretuser&token=secretpass
    #EXTINF:-1 group-title="SERIES",Show S01E01
    http://cdn.example.invalid/s/secretpass/e1.mp4
    """
    let c = M3UMapper.catalog(from: M3UParser.parse(text), secret: m3uSecret(user, pass))
    var strings: [String] = []
    for loc in c.live.map(\.locator) + c.movies.map(\.locator) + c.episodes.map(\.locator) {
        if case let .template(t) = loc { strings.append(t) }
    }
    strings += c.live.map(\.providerID) + c.movies.map(\.providerID) + c.episodes.map(\.providerID) + c.series.map(\.providerID)
    #expect(strings.count == 7)
    for s in strings { #expect(!s.contains(user) && !s.contains(pass)) }
}
