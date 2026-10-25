import Testing
import Foundation
import Core
import Providers
@testable import AnonymizeKit

private func xtream(_ s: String) throws -> (URL, String, String) {
    guard case let .xtream(server, u, p) = try parseSource(s) else { Issue.record("not xtream"); throw CLIFailure(code: 0, message: "") }
    return (server, u, p)
}

@Test func parsesXtreamPaths() throws {
    for path in ["player_api.php", "get.php", "xmltv.php"] {
        let (server, u, p) = try xtream("http://h.example:8080/\(path)?username=alice&password=pw%26x&type=m3u\n")
        #expect(server.absoluteString == "http://h.example:8080")
        #expect(u == "alice"); #expect(p == "pw&x")
    }
}

@Test func keepsSubpathInServer() throws {
    let (server, _, _) = try xtream("http://h.example/panel/player_api.php?username=a&password=b")
    #expect(server.absoluteString == "http://h.example/panel")
}

@Test func bareServerNeedsCredentials() throws {
    let (server, u, _) = try xtream("http://h.example:80/?username=a&password=b")
    #expect(server.absoluteString == "http://h.example:80"); #expect(u == "a")
    #expect(throws: CLIFailure.self) { try parseSource("http://h.example:80/get.php") }
    // Bar server utan credentials är en M3U-URL.
    guard case .m3u = try parseSource("http://h.example:80") else { Issue.record("expected m3u"); return }
}

@Test func otherUrlsAreM3U() throws {
    guard case let .m3u(url, epg) = try parseSource("https://h.example/list.m3u8?token=1") else { Issue.record("expected m3u"); return }
    #expect(url.absoluteString == "https://h.example/list.m3u8?token=1"); #expect(epg == nil)
}

@Test func rejectsMultiLineAndEmptyInput() {
    #expect(throws: CLIFailure.self) { try parseSource("http://a.example/x.m3u\nhttp://b.example/y.m3u") }
    #expect(throws: CLIFailure.self) { try parseSource("") }
    #expect(throws: CLIFailure.self) { try parseSource("\n  \n") }
    #expect(throws: CLIFailure.self) { try parseSource("ftp://a.example/x") }
}

@Test func stripsBOMAndTrailingBlankLines() throws {
    let (server, u, _) = try xtream("\u{FEFF}http://h.example/get.php?username=a&password=b\r\n\r\n")
    #expect(server.absoluteString == "http://h.example"); #expect(u == "a")
}

@Test func placeholderURLHasNoSecretsOrPorts() {
    let secret = PlaylistSecret.xtream(server: URL(string: "http://203.0.113.7:8080")!, username: "u", password: "p")
    for l in [StreamLocator.xtream(kind: .movie, streamID: "5", container: "mkv"),
              .template("{server}/play/{username}/9.m3u8?token={password}"),
              .template("http://user:pw@cdn.example.net:81/x/1.ts?k=v#f")] {
        let url = placeholderURL(l)
        let c = URLComponents(string: url)
        #expect(c?.host == "example.invalid", "\(url)")
        #expect(c?.query == nil); #expect(c?.user == nil); #expect(c?.port == nil); #expect(c?.fragment == nil)
        _ = secret
    }
    #expect(placeholderURL(.xtream(kind: .movie, streamID: "5", container: "mkv")) == "http://example.invalid/movie/REDACTED/REDACTED/5.mkv")
}

@Test func anonymizedAssetKeepsOnlyFileName() {
    let u = anonymizedAsset(URL(string: "http://user:pw@img.example.net:8080/secret/dir/poster.jpg?token=abc#x"))
    #expect(u?.absoluteString == "https://example.invalid/poster.jpg")
    #expect(anonymizedAsset(nil) == nil)
}

@Test func rewritesTemplateLocators() {
    #expect(anonymizedTemplate("http://cdn.example.net:8080/tok123/play/abc/42.m3u8?token=xyz&a=1")
        == "http://example.invalid/REDACTED/play/REDACTED/42.m3u8?token=REDACTED&a=REDACTED")
    #expect(!anonymizedTemplate("http://cdn.example.net/tok123/live/9").contains("tok123"))
    #expect(anonymizedTemplate("{server}/play/{username}/9.m3u8?token={password}") == "{server}/play/{username}/9.m3u8?token=REDACTED")
    #expect(anonymizedTemplate("{server}/{username}/{password}/123") == "{server}/{username}/{password}/123")
}

@Test func fixtureCatalogCapsAndAnonymizes() throws {
    var c = ProviderCatalog()
    for i in 0..<400 {
        c.categories.append(Category(providerID: "\(i)", name: "C\(i)", kind: .live, sortIndex: i))
        c.live.append(LiveStream(providerID: "l\(i)", name: "L\(i)", logoURL: URL(string: "http://10.9.8.7/logos/l\(i).png"),
                                 locator: .template("http://203.0.113.9:8000/tokenabc/live/secret\(i)/\(i).ts?auth=zzz")))
    }
    let fx = fixtureCatalog(c)
    #expect(fx.categories.count == 300); #expect(fx.live.count == 300)
    let files = try renderFixtures(c)
    #expect(files.map(\.name).contains("sample.m3u"))
    for f in files { #expect(fixtureLeaks(in: f.text) == 0, "\(f.name)") }
    #expect(!files.contains { $0.text.contains("203.0.113.9") || $0.text.contains("zzz") || $0.text.contains("secret1") })
}

@Test func fixtureLeakGuardCountsForeignUrlsAndIPv4() {
    #expect(fixtureLeaks(in: "http://example.invalid/a https://image.tmdb.org/t/p/x.jpg") == 0)
    #expect(fixtureLeaks(in: "http://cdn.example.net/a") == 1)
    let bs = String(UnicodeScalar(92))   // omvänt snedstreck, som i JSON med escapade snedstreck
    #expect(fixtureLeaks(in: "https:" + bs + "/" + bs + "/cdn.example.net" + bs + "/a") == 1)
    #expect(fixtureLeaks(in: "http://user:pw@example.invalid/a") == 1)
    #expect(fixtureLeaks(in: "x 203.0.113.7 y") == 1)
    #expect(fixtureLeaks(in: "http://203.0.113.7:8080/a") == 2)
    #expect(fixtureLeaks(in: "Title 2.0 and 1.2.3 and 1080p") == 0)
}

@Test func percentAndShortCredentials() {
    #expect(percent(1, of: 3) == "33.3"); #expect(percent(0, of: 0) == "0.0"); #expect(percent(2, of: 2) == "100.0")
    let u = URL(string: "http://h.example")!
    #expect(hasShortCredentials(.xtream(server: u, username: "abc", password: "longenough")))
    #expect(!hasShortCredentials(.xtream(server: u, username: "alice", password: "longenough")))
    #expect(hasShortCredentials(.m3u(url: URL(string: "http://h/get.php?username=ab&password=xyz12")!, epgURL: nil)))
}

@Test func unreachableDetection() {
    #expect(isUnreachable(ProviderError.unreachable))
    #expect(isUnreachable(URLError(.timedOut)))
    #expect(!isUnreachable(ProviderError.unauthorized))
    #expect(!isUnreachable(URLError(.badURL)))
}

// MARK: - Tokens i path-segment

@Test func tokenLikeSegmentsAreRedacted() {
    // Delarna sätts ihop i körtid så att gitleaks JWT-regel inte slår på testkoden.
    let jwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"]
        .joined(separator: ".")
    #expect(anonymizedTemplate("{server}/hls/\(jwt)/1.m3u8") == "{server}/hls/REDACTED/1.m3u8")
    #expect(anonymizedTemplate("{server}/live/token.ts") == "{server}/live/REDACTED")
    #expect(anonymizedTemplate("{server}/live/123456789/5") == "{server}/live/REDACTED/5")
    #expect(anonymizedTemplate("{server}/live/1234567/12345.ts") == "{server}/live/1234567/12345.ts")
    #expect(anonymizedTemplate("{server}/movie/42.MKV") == "{server}/movie/42.MKV")
    #expect(anonymizedTemplate("{server}/x/42.php") == "{server}/REDACTED/REDACTED")
    #expect(anonymizedTemplate("{server}/x/abc123.mp4") == "{server}/REDACTED/REDACTED")
}

@Test func fixtureLeakGuardCountsTokens() {
    #expect(fixtureLeaks(in: "seg 3f9a1c0b7e5d4a2b8c6f0e1d2a3b4c5d end") == 1)
    let jwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiJ4In0", "c2lnbmF0dXJl"].joined(separator: ".")
    #expect(fixtureLeaks(in: "a \(jwt) b") >= 1)
    #expect(fixtureLeaks(in: "abcdefgh.ijklmnop.qrstuvwx") == 1)
    // Vanliga titlar, långa ord utan siffror och korta id:n flaggas inte.
    #expect(fixtureLeaks(in: "The Lord of the Rings: The Return of the King (2003) 1080p") == 0)
    #expect(fixtureLeaks(in: "Supercalifragilisticexpialidocious S01E02 m3u:af63dc4c8601ec8c") == 0)
    #expect(fixtureLeaks(in: "\"title\" : \"Severance S02E04\", \"id\" : \"1234567\"") == 0)
}

@Test func tokenLikeAssetNamesAreReplaced() {
    #expect(anonymizedAsset(URL(string: "https://image.tmdb.org/t/p/w500/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg"))?.absoluteString
        == "https://example.invalid/x.jpg")
}
