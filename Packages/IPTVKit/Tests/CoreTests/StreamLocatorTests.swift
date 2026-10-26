import Foundation
import Testing
@testable import Core

@Test func xtreamLocatorResolves() throws {
    let s = PlaylistSecret.xtream(server: URL(string: "http://host.example:8080")!, username: "u", password: "p")
    #expect(try StreamLocator.xtream(kind: .movie, streamID: "42", container: "mkv").resolve(with: s).absoluteString
            == "http://host.example:8080/movie/u/p/42.mkv")
    #expect(try StreamLocator.xtream(kind: .series, streamID: "7", container: "mp4").resolve(with: s).absoluteString
            == "http://host.example:8080/series/u/p/7.mp4")
    #expect(try StreamLocator.xtream(kind: .live, streamID: "9", container: "m3u8").resolve(with: s).absoluteString
            == "http://host.example:8080/live/u/p/9.m3u8")
}

@Test func templateLocatorResolvesAndEscapes() throws {
    let s = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "a b", password: "p&w")
    #expect(try StreamLocator.template("{server}/x?u={username}&p={password}").resolve(with: s).absoluteString
            == "http://h:1/x?u=a%20b&p=p%26w")
}

@Test func xtreamLocatorWithM3USecretThrows() {
    #expect(throws: CoreError.secretKindMismatch) {
        try StreamLocator.xtream(kind: .movie, streamID: "1", container: "mp4")
            .resolve(with: .m3u(url: URL(string: "http://h/p.m3u")!, epgURL: nil))
    }
}

@Test func xtreamLocatorWithXtreamStyleM3UResolves() throws {
    let s = PlaylistSecret.m3u(url: URL(string: "http://h:80/get.php?username=u&password=p&type=m3u")!, epgURL: nil)
    #expect(try StreamLocator.xtream(kind: .live, streamID: "9", container: "ts").resolve(with: s).absoluteString
            == "http://h:80/live/u/p/9.ts")
}

@Test func templateWithM3USecretUsesQueryItems() throws {
    let s = PlaylistSecret.m3u(url: URL(string: "http://h:80/get.php?username=u&password=p")!, epgURL: nil)
    #expect(try StreamLocator.template("{server}/a/{username}/{password}").resolve(with: s).absoluteString
            == "http://h:80/a/u/p")
}

@Test func invalidTemplateThrows() {
    let s = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "u", password: "p")
    #expect(throws: CoreError.invalidURL) { try StreamLocator.template("").resolve(with: s) }
}

@Test func locatorCodableRoundTrip() throws {
    let l = StreamLocator.xtream(kind: .movie, streamID: "1", container: "mp4")
    let data = try JSONEncoder().encode(l)
    #expect(try JSONDecoder().decode(StreamLocator.self, from: data) == l)
}

@Test(arguments: ["p+w", "p/w", "p%w", "påß wörd", "ü🙂"])
func specialPasswordsRoundTrip(pw: String) throws {
    let s = PlaylistSecret.xtream(server: URL(string: "http://h.example:8080/")!, username: "u", password: pw)
    let url = try StreamLocator.xtream(kind: .movie, streamID: "1", container: "mkv").resolve(with: s)
    let segment = url.pathComponents[3]
    // pathComponents avkodar på Apple men inte nödvändigtvis på Linux; avkoda bara om det behövs.
    #expect(segment == pw || segment.removingPercentEncoding == pw)
    #expect(url.absoluteString.hasPrefix("http://h.example:8080/movie/u/"))
}

@Test func templateNeedingCredentialsWithoutThemThrows() {
    #expect(throws: CoreError.missingCredentials) {
        try StreamLocator.template("{server}/x/{username}/{password}/1.ts")
            .resolve(with: .m3u(url: URL(string: "http://h.example/list.m3u")!, epgURL: nil))
    }
}

@Test func serverOnlyTemplateResolvesWithoutCredentials() throws {
    let s = PlaylistSecret.m3u(url: URL(string: "http://h.example/list.m3u")!, epgURL: nil)
    #expect(try StreamLocator.template("{server}/x/1.ts").resolve(with: s).absoluteString == "http://h.example/x/1.ts")
}
