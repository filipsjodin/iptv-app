import Testing
import Foundation
import Providers
@testable import Subtitles

private let key = "fakeoskey-123456"
private let user = "fake-user-xyz"
private let pass = "fake-pass-qrs"
private let token = "faketokenabc"

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private struct Recorded: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

private final class MockHTTP: HTTPClient, @unchecked Sendable {
    typealias Reply = (Data, Int, [String: String])
    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private var handler: @Sendable (Recorded) throws -> Reply
    init(_ handler: @escaping @Sendable (Recorded) throws -> Reply) { self.handler = handler }

    var requests: [Recorded] { lock.withLock { _requests } }

    private func run(_ r: Recorded) throws -> Reply {
        lock.withLock { _requests.append(r) }
        return try handler(r)
    }
    func get(_ url: URL) async throws -> (Data, Int) {
        let (d, s, _) = try run(Recorded(method: "GET", url: url, headers: [:], body: nil))
        return (d, s)
    }
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        try run(Recorded(method: "GET", url: url, headers: headers, body: nil))
    }
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int, [String: String]) {
        try run(Recorded(method: "POST", url: url, headers: headers, body: body))
    }
}

private func items(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[i.name] = i.value }
    return out
}

/// Standardserver: login, search, download (+ länk), user.
private func server(downloadStatus: Int = 200, downloadBody: Data? = nil, downloadHeaders: [String: String] = [:]) throws -> MockHTTP {
    let login = try fixture("os-login"), search = try fixture("os-search")
    let dl = try fixture("os-download"), usr = try fixture("os-user")
    return MockHTTP { r in
        switch (r.method, r.url.path) {
        case ("POST", "/api/v1/login"): return (login, 200, [:])
        case ("GET", "/api/v1/subtitles"): return (search, 200, [:])
        case ("POST", "/api/v1/download"): return (downloadBody ?? dl, downloadStatus, downloadHeaders)
        case ("GET", "/api/v1/infos/user"): return (usr, 200, [:])
        case ("GET", "/download/abc123/sample.srt"): return (Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8), 200, [:])
        default: return (Data(), 404, [:])
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

struct OpenSubtitlesClientTests {
    @Test func searchBuildsQueryFromTmdbSeasonEpisode() async throws {
        let http = try server()
        let c = OpenSubtitlesClient(apiKey: key, http: http)
        _ = try await c.search(OpenSubtitlesQuery(tmdbID: 1399, season: 1, episode: 2, languages: ["sv", "en"]))
        let r = try #require(http.requests.first)
        let q = items(r.url)
        #expect(r.url.host == "api.opensubtitles.com")
        #expect(q["parent_tmdb_id"] == "1399" && q["season_number"] == "1" && q["episode_number"] == "2")
        #expect(q["languages"] == "sv,en")
        #expect(r.headers["Api-Key"] == key)
        #expect(r.headers["User-Agent"] == "IPTVApp v1.0")
        #expect(r.headers["Content-Type"] == "application/json")
    }

    @Test func searchUsesTmdbIDForMovies() async throws {
        let http = try server()
        _ = try await OpenSubtitlesClient(apiKey: key, http: http).search(OpenSubtitlesQuery(tmdbID: 603, languages: ["sv"]))
        let q = items(try #require(http.requests.first).url)
        #expect(q["tmdb_id"] == "603" && q["parent_tmdb_id"] == nil)
    }

    @Test func searchFallsBackToTitleQuery() async throws {
        let http = try server()
        _ = try await OpenSubtitlesClient(apiKey: key, http: http).search(OpenSubtitlesQuery(title: "The Matrix", year: 1999, languages: ["sv"]))
        let q = items(try #require(http.requests.first).url)
        #expect(q["query"] == "The Matrix" && q["year"] == "1999")
        #expect(q["tmdb_id"] == nil && q["imdb_id"] == nil)
    }

    @Test func searchParsesFixtureAndMapsFields() async throws {
        let c = OpenSubtitlesClient(apiKey: key, http: try server())
        let res = try await c.search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv", "en"]))
        #expect(res.count == 2)  // posten utan filer hoppas över
        #expect(res[0] == OpenSubtitlesResult(id: 501001, language: "sv", release: "Show.S01E02.1080p.WEB", fileName: "Show.S01E02.sv.srt",
                                              rating: 7.5, downloadCount: 5400, hearingImpaired: false, aiTranslated: false))
        #expect(res[1].id == 501002 && res[1].hearingImpaired && res[1].aiTranslated && res[1].rating == 0)
    }

    @Test func searchIsCachedForTenMinutes() async throws {
        let http = try server()
        let clock = Clock()
        let c = OpenSubtitlesClient(apiKey: key, http: http, now: { clock.now })
        let q = OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"])
        _ = try await c.search(q)
        clock.advance(599)
        _ = try await c.search(q)
        #expect(http.requests.count == 1)
        clock.advance(2)
        _ = try await c.search(q)
        #expect(http.requests.count == 2)
        _ = try await c.search(OpenSubtitlesQuery(tmdbID: 2, languages: ["sv"]))
        #expect(http.requests.count == 3)
    }

    @Test func searchWithoutAPIKeyThrowsNoAPIKey() async throws {
        let http = try server()
        for k in [nil, ""] as [String?] {
            await #expect(throws: OpenSubtitlesError.noAPIKey) {
                try await OpenSubtitlesClient(apiKey: k, http: http).search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"]))
            }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func downloadRequiresLogin() async throws {
        let http = try server()
        await #expect(throws: OpenSubtitlesError.notLoggedIn) {
            try await OpenSubtitlesClient(apiKey: key, http: http).download(fileID: 1)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func loginStoresTokenAndUsesItForDownload() async throws {
        let http = try server()
        let c = OpenSubtitlesClient(apiKey: key, http: http)
        #expect(!c.isLoggedIn)
        let quota = try await c.login(username: user, password: pass)
        #expect(c.isLoggedIn)
        #expect(quota.allowed == 100)
        let body = try #require(http.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["username": user, "password": pass])
        _ = try await c.download(fileID: 501001)
        let dl = try #require(http.requests.first { $0.url.path.hasSuffix("/download") })
        #expect(dl.headers["Authorization"] == "Bearer \(token)")
        #expect(dl.headers["Api-Key"] == key)
        // Inloggningssvaret pekar ut en annan värd som ska användas.
        #expect(dl.url.host == "vip-api.opensubtitles.com")
        c.logout()
        #expect(!c.isLoggedIn)
        await #expect(throws: OpenSubtitlesError.notLoggedIn) { try await c.download(fileID: 1) }
    }

    @Test func invalidCredentialsOn401AtLogin() async throws {
        let http = MockHTTP { _ in (Data(), 401, [:]) }
        let c = OpenSubtitlesClient(apiKey: key, http: http)
        await #expect(throws: OpenSubtitlesError.invalidCredentials) { try await c.login(username: user, password: pass) }
        #expect(!c.isLoggedIn)
    }

    @Test func unauthorizedRefreshesTokenOnce() async throws {
        // 401 vid nedladdning: klienten loggar inte in på nytt själv, utan glömmer token.
        let http = try server(downloadStatus: 401, downloadBody: Data("{}".utf8))
        let c = OpenSubtitlesClient(apiKey: key, http: http)
        _ = try await c.login(username: user, password: pass)
        await #expect(throws: OpenSubtitlesError.notLoggedIn) { try await c.download(fileID: 1) }
        #expect(!c.isLoggedIn)
        #expect(http.requests.filter { $0.url.path.hasSuffix("/login") }.count == 1)
    }

    @Test func downloadFollowsLinkAndReturnsBytes() async throws {
        let http = try server()
        let c = OpenSubtitlesClient(apiKey: key, http: http)
        _ = try await c.login(username: user, password: pass)
        let (data, quota) = try await c.download(fileID: 501001)
        #expect(String(decoding: data, as: UTF8.self).contains("Hej"))
        #expect(quota.remaining == 87)
        #expect(quota.resetAt == Date(timeIntervalSince1970: 1_793_491_200))  // 2026-11-01T00:00:00Z
        let link = try #require(http.requests.last)
        #expect(link.method == "GET" && link.url.host == "dl.example-subs.test")
        #expect(link.headers["Authorization"] == nil && link.headers["Api-Key"] == nil)
        let req = try #require(http.requests.first { $0.url.path.hasSuffix("/download") })
        let reqBody = try #require(req.body)
        let json = try #require(try JSONSerialization.jsonObject(with: reqBody) as? [String: Int])
        #expect(json == ["file_id": 501001])
    }

    @Test func quotaExhaustedOnHttp406() async throws {
        let body = Data(#"{"message":"You have downloaded your allowed 100 subtitles","remaining":0,"reset_time_utc":"2026-11-01T00:00:00.000Z"}"#.utf8)
        let c = OpenSubtitlesClient(apiKey: key, http: try server(downloadStatus: 406, downloadBody: body))
        _ = try await c.login(username: user, password: pass)
        await #expect(throws: OpenSubtitlesError.quotaExhausted(resetAt: Date(timeIntervalSince1970: 1_793_491_200))) {
            try await c.download(fileID: 1)
        }
        #expect(c.isLoggedIn)
    }

    @Test func rateLimitedOnHttp429ReadsRetryAfter() async throws {
        let c = OpenSubtitlesClient(apiKey: key, http: try server(downloadStatus: 429, downloadBody: Data(), downloadHeaders: ["retry-after": "7"]))
        _ = try await c.login(username: user, password: pass)
        await #expect(throws: OpenSubtitlesError.rateLimited(retryAfter: 7)) { try await c.download(fileID: 1) }
        let noHeader = OpenSubtitlesClient(apiKey: key, http: MockHTTP { _ in (Data(), 429, [:]) })
        await #expect(throws: OpenSubtitlesError.rateLimited(retryAfter: nil)) {
            try await noHeader.search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"]))
        }
    }

    @Test func quotaReadsUserInfo() async throws {
        let c = OpenSubtitlesClient(apiKey: key, http: try server())
        await #expect(throws: OpenSubtitlesError.notLoggedIn) { try await c.quota() }
        _ = try await c.login(username: user, password: pass)
        let q = try await c.quota()
        #expect(q.allowed == 100 && q.remaining == 88)
    }

    @Test func networkAndBadResponseMapToFixedErrors() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "https://secret.host/\(key)" } }
        let failing = MockHTTP { _ in throw Boom() }
        await #expect(throws: OpenSubtitlesError.network) {
            try await OpenSubtitlesClient(apiKey: key, http: failing).search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"]))
        }
        let garbage = MockHTTP { _ in (Data("nope".utf8), 200, [:]) }
        await #expect(throws: OpenSubtitlesError.badResponse) {
            try await OpenSubtitlesClient(apiKey: key, http: garbage).search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"]))
        }
    }

    @Test func errorsNeverContainCredentialsOrKey() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "\(key) \(user) \(pass) \(token)" } }
        let secrets = [key, user, pass, token]
        var errors: [any Error] = []
        let all: [OpenSubtitlesError] = [.noAPIKey, .notLoggedIn, .invalidCredentials, .quotaExhausted(resetAt: Date()),
                                         .rateLimited(retryAfter: 3), .network, .badResponse]
        errors.append(contentsOf: all)
        let leaky = MockHTTP { _ in throw Boom() }
        let c = OpenSubtitlesClient(apiKey: key, http: leaky)
        do { _ = try await c.login(username: user, password: pass) } catch { errors.append(error) }
        do { _ = try await c.search(OpenSubtitlesQuery(tmdbID: 1, languages: ["sv"])) } catch { errors.append(error) }
        let bad = MockHTTP { _ in (Data("\(key)\(user)\(pass)\(token)".utf8), 500, [:]) }
        do { _ = try await OpenSubtitlesClient(apiKey: key, http: bad).login(username: user, password: pass) } catch { errors.append(error) }
        #expect(errors.count > all.count)
        for e in errors {
            for text in [String(describing: e), String(reflecting: e), "\(e)", e.localizedDescription] {
                for s in secrets { #expect(!text.contains(s)) }
            }
        }
        // Själva klienten läcker inte heller.
        let live = OpenSubtitlesClient(apiKey: key, http: try server())
        _ = try await live.login(username: user, password: pass)
        for text in [String(describing: live), String(reflecting: live), "\(Mirror(reflecting: live).children.count)"] {
            for s in secrets { #expect(!text.contains(s)) }
        }
    }
}

struct OpenSubtitlesClientHardeningTests {
    @Test func episodeWithoutIDsFallsBackToTitle() async throws {
        let http = try server()
        _ = try await OpenSubtitlesClient(apiKey: key, http: http)
            .search(OpenSubtitlesQuery(season: 2, episode: 5, title: "Show", year: 2020, languages: ["sv"]))
        let q = items(try #require(http.requests.first).url)
        #expect(q["query"] == "Show" && q["year"] == "2020")
        #expect(q["season_number"] == "2" && q["episode_number"] == "5")
    }

    @Test func titleIsNotSentWhenAnIDIsPresent() async throws {
        let http = try server()
        _ = try await OpenSubtitlesClient(apiKey: key, http: http)
            .search(OpenSubtitlesQuery(tmdbID: 5, season: 1, episode: 1, title: "Show", languages: ["sv"]))
        #expect(items(try #require(http.requests.first).url)["query"] == nil)
    }

    @Test func queryEncodesPlusAmpersandAccentsAndSpaces() async throws {
        let http = try server()
        _ = try await OpenSubtitlesClient(apiKey: key, http: http)
            .search(OpenSubtitlesQuery(title: "C++ & Å ä=ö", languages: ["sv"]))
        let url = try #require(http.requests.first).url
        let raw = url.absoluteString
        #expect(raw.contains("query=C%2B%2B%20%26%20%C3%85%20%C3%A4%3D%C3%B6"))
        #expect(items(url)["query"] == "C++ & Å ä=ö")
    }

    @Test func hostileBaseURLFromLoginFallsBackToDefaultHost() async throws {
        let hostile = ["evil.com", "x.opensubtitles.com.evil.com", "api.opensubtitles.com:8080", "user@evil.com",
                       "http://evil.com", "http://api.opensubtitles.com", "evil.com/opensubtitles.com", "opensubtitles.com.evil.com"]
        for bad in hostile {
            let login = Data(#"{"token":"faketokenabc","base_url":"\#(bad)","user":{"allowed_downloads":100}}"#.utf8)
            let dl = try fixture("os-download")
            let http = MockHTTP { r in
                switch (r.method, r.url.path) {
                case ("POST", "/api/v1/login"): return (login, 200, [:])
                case ("POST", "/api/v1/download"): return (dl, 200, [:])
                default: return (Data("x".utf8), 200, [:])
                }
            }
            let c = OpenSubtitlesClient(apiKey: key, http: http)
            _ = try await c.login(username: user, password: pass)
            _ = try await c.download(fileID: 1)
            let post = try #require(http.requests.first { $0.url.path.hasSuffix("/download") })
            #expect(post.url.host == "api.opensubtitles.com" && post.url.port == nil && post.url.user == nil, "base_url \(bad)")
            // Token går bara till OpenSubtitles egna värdar.
            for r in http.requests where r.headers["Authorization"] != nil {
                #expect(r.url.host == "api.opensubtitles.com")
            }
        }
    }

    @Test func unsafeDownloadLinksAreRejected() async throws {
        for link in ["http://dl.example-subs.test/a.srt", "https:///a.srt", "file:///etc/passwd", "ftp://dl.example-subs.test/a", "not a url", ""] {
            let body = Data(#"{"link":"\#(link)","remaining":5}"#.utf8)
            let http = try server(downloadBody: body)
            let c = OpenSubtitlesClient(apiKey: key, http: http)
            _ = try await c.login(username: user, password: pass)
            await #expect(throws: OpenSubtitlesError.badResponse, "link \(link)") { try await c.download(fileID: 1) }
            // Ingen begäran gick till länken.
            #expect(http.requests.allSatisfy { $0.url.host?.hasSuffix("opensubtitles.com") == true })
        }
        let missing = try server(downloadBody: Data(#"{"remaining":5}"#.utf8))
        let c = OpenSubtitlesClient(apiKey: key, http: missing)
        _ = try await c.login(username: user, password: pass)
        await #expect(throws: OpenSubtitlesError.badResponse) { try await c.download(fileID: 1) }
    }
}
