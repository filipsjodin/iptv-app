import Testing
import Foundation
import Core
import ProvidersTestSupport
@testable import Providers

@Suite struct EPGSourceTests {
    @Test func xtreamUrlHasXmltvPathAndCredentials() throws {
        let secret = PlaylistSecret.xtream(server: URL(string: "http://example.test:8080")!, username: "user", password: "pw")
        let url = try #require(EPGSource.url(for: secret))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "example.test")
        #expect(comps.port == 8080)
        #expect(comps.path == "/xmltv.php")
        #expect(comps.queryItems?.first { $0.name == "username" }?.value == "user")
        #expect(comps.queryItems?.first { $0.name == "password" }?.value == "pw")
    }

    @Test func xtreamSpecialCharactersArePercentEncoded() throws {
        let secret = PlaylistSecret.xtream(server: URL(string: "http://example.test/base")!, username: "a b&c", password: "p=1#2+3")
        let url = try #require(EPGSource.url(for: secret))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/base/xmltv.php")
        #expect(comps.queryItems?.first { $0.name == "username" }?.value == "a b&c")
        #expect(comps.queryItems?.first { $0.name == "password" }?.value == "p=1#2+3")
        let s = url.absoluteString
        #expect(!s.contains(" "))
        #expect(!s.contains("#"))
        #expect(s.filter { $0 == "&" }.count == 1)
    }

    @Test func m3uReturnsEpgURL() throws {
        let epg = URL(string: "http://example.test/guide.xml.gz")!
        #expect(EPGSource.url(for: .m3u(url: URL(string: "http://example.test/list.m3u")!, epgURL: epg)) == epg)
    }

    @Test func m3uWithoutEpgURLIsNil() {
        #expect(EPGSource.url(for: .m3u(url: URL(string: "http://example.test/list.m3u")!, epgURL: nil)) == nil)
    }

    @Test func downloadErrorDescriptionNeverContainsURL() throws {
        let secret = PlaylistSecret.xtream(server: URL(string: "http://secret-host.test:9090")!, username: "uname1", password: "pword1")
        let url = try #require(EPGSource.url(for: secret))
        let errors: [ProviderError] = [.unreachable, .http(404), .invalidResponse]
        for e in errors {
            let text = Redactor.redact("\(e)", secret: secret)
            #expect(text == "\(e)")
            #expect(!"\(e)".contains(url.host!))
            #expect(!"\(e)".contains("uname1"))
            #expect(!"\(e)".contains("pword1"))
        }
    }

    @Test func defaultDownloadWritesBodyToFile() async throws {
        let client = StubHTTPClient(responses: ["": StubResponse(body: Data("<tv/>".utf8), status: 200)], key: { _ in "" })
        let (file, status) = try await client.download(URL(string: "http://example.test/x")!)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(status == 200)
        #expect(try String(contentsOf: file, encoding: .utf8) == "<tv/>")
    }
}
