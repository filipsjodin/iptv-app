import Core
import Foundation
import Providers
import Subtitles
import Testing

@testable import Library

private let apiKey = "fakeoskey-123456"
private let userName = "fake-user-xyz"
private let passWord = "fake-pass-qrs"
private let sPlaylist = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
private let sProfile = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

private struct Recorded: Sendable {
    var method: String
    var url: URL
    var body: Data?
}

private final class MockHTTP: HTTPClient, @unchecked Sendable {
    typealias Reply = (Data, Int, [String: String])
    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private let handler: @Sendable (Recorded) throws -> Reply

    init(_ handler: @escaping @Sendable (Recorded) throws -> Reply) { self.handler = handler }

    var requests: [Recorded] { lock.withLock { _requests } }

    private func run(_ r: Recorded) throws -> Reply {
        lock.withLock { _requests.append(r) }
        return try handler(r)
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        let (d, s, _) = try run(Recorded(method: "GET", url: url, body: nil))
        return (d, s)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        try run(Recorded(method: "GET", url: url, body: nil))
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int, [String: String]) {
        try run(Recorded(method: "POST", url: url, body: body))
    }
}

private let loginJSON = Data(#"{"token":"tok-abc","user":{"allowed_downloads":100,"remaining_downloads":99}}"#.utf8)
private let downloadJSON = Data(#"{"link":"https://dl.opensubtitles.com/f/abc.srt","remaining":98}"#.utf8)
private let srtBody = Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8)

private func searchJSON(_ items: [(id: Int, lang: String, rating: Double, downloads: Int)]) -> Data {
    let rows = items.map {
        #"{"attributes":{"language":"\#($0.lang)","release":"r\#($0.id)","ratings":\#($0.rating),"download_count":\#($0.downloads),"files":[{"file_id":\#($0.id),"file_name":"f.srt"}]}}"#
    }
    return Data(#"{"data":[\#(rows.joined(separator: ","))]}"#.utf8)
}

/// Standardserver: inloggning, nedladdning (+ länk) och sökning.
private func server(search: Data = Data(#"{"data":[]}"#.utf8), loginStatus: Int = 200) -> MockHTTP {
    MockHTTP { r in
        switch (r.method, r.url.path) {
        case ("POST", "/api/v1/login"): return (loginStatus == 200 ? loginJSON : Data(), loginStatus, [:])
        case ("POST", "/api/v1/download"): return (downloadJSON, 200, [:])
        case ("GET", "/f/abc.srt"): return (srtBody, 200, [:])
        case ("GET", "/api/v1/subtitles"): return (search, 200, [:])
        case ("GET", "/api/v1/infos/user"):
            return (Data(#"{"data":{"allowed_downloads":100,"remaining_downloads":50}}"#.utf8), 200, [:])
        default: return (Data(), 404, [:])
        }
    }
}

private struct ServiceFixture {
    let service: SubtitleService
    let client: OpenSubtitlesClient
    let store: SubtitleStore
    let credentials: InMemoryOpenSubtitlesCredentialStore
    let http: MockHTTP
    let directory: URL
}

private func makeService(http: MockHTTP, saved: OpenSubtitlesCredentials? = nil) throws -> ServiceFixture {
    let db = try AppDatabase.inMemory()
    try LibraryStore(db: db).upsertPlaylist(
        Playlist(id: sPlaylist, name: "A", kind: .xtream, createdAt: Date(timeIntervalSince1970: 1000)))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("subtitle-service-tests-\(UUID().uuidString)", isDirectory: true)
    let store = SubtitleStore(db: db, directory: directory)
    let client = OpenSubtitlesClient(apiKey: apiKey, http: http)
    let credentials = InMemoryOpenSubtitlesCredentialStore(saved)
    return ServiceFixture(
        service: SubtitleService(client: client, store: store, credentials: credentials),
        client: client, store: store, credentials: credentials, http: http, directory: directory)
}

private func subtitleKey() -> SubtitleKey {
    SubtitleKey(profileID: sProfile, playlistID: sPlaylist, kind: .movie, providerID: "m1")
}

private func osResult(_ id: Int) -> OpenSubtitlesResult {
    OpenSubtitlesResult(id: id, language: "sv", release: "Rel", fileName: "f.srt", rating: 8, downloadCount: 10,
                        hearingImpaired: false, aiTranslated: false)
}

private let saved = OpenSubtitlesCredentials(username: userName, password: passWord)

@Test func searchSortsPreferredLanguagesThenRatingThenDownloads() async throws {
    let json = searchJSON([
        (1, "en", 9, 10), (2, "sv", 5, 10), (3, "sv", 8, 1), (4, "sv", 8, 50), (5, "da", 10, 99),
    ])
    let f = try makeService(http: server(search: json))
    let results = try await f.service.search(OpenSubtitlesQuery(tmdbID: 603, languages: ["sv", "en"]),
                                             preferredLanguages: ["sv", "en"])
    #expect(results.map(\.id) == [4, 3, 2, 1, 5])
}

@Test func downloadLogsInWithStoredCredentialsWhenNeeded() async throws {
    let f = try makeService(http: server(), saved: saved)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    #expect(!f.client.isLoggedIn)
    let (stored, quota) = try await f.service.download(osResult(9), for: subtitleKey())
    #expect(f.client.isLoggedIn)
    #expect(quota.remaining == 98)
    #expect(stored.id == 9)
    #expect(try f.store.list(for: subtitleKey()).map(\.id) == [9])
    let logins = f.http.requests.filter { $0.method == "POST" && $0.url.path == "/api/v1/login" }
    #expect(logins.count == 1)
    let body = String(decoding: logins[0].body ?? Data(), as: UTF8.self)
    #expect(body.contains(userName) && body.contains(passWord))

    // Redan inloggad: ingen ny inloggning.
    _ = try await f.service.download(osResult(10), for: subtitleKey())
    #expect(f.http.requests.filter { $0.url.path == "/api/v1/login" }.count == 1)
}

@Test func downloadWithoutCredentialsThrowsNotLoggedIn() async throws {
    let f = try makeService(http: server())
    await #expect(throws: OpenSubtitlesError.notLoggedIn) {
        _ = try await f.service.download(osResult(9), for: subtitleKey())
    }
    #expect(f.http.requests.isEmpty)
    #expect(try f.store.list(for: subtitleKey()).isEmpty)
}

@Test func loginSavesCredentialsOnlyOnSuccess() async throws {
    let bad = try makeService(http: server(loginStatus: 401))
    await #expect(throws: OpenSubtitlesError.invalidCredentials) {
        _ = try await bad.service.login(username: userName, password: passWord)
    }
    #expect(try bad.credentials.load() == nil)

    let good = try makeService(http: server())
    let quota = try await good.service.login(username: userName, password: passWord)
    #expect(quota.remaining == 99)
    #expect(try good.credentials.load() == saved)
}

@Test func logoutClearsKeychainAndToken() async throws {
    let f = try makeService(http: server())
    _ = try await f.service.login(username: userName, password: passWord)
    #expect(f.client.isLoggedIn)
    try f.service.logout()
    #expect(!f.client.isLoggedIn)
    #expect(try f.credentials.load() == nil)
    await #expect(throws: OpenSubtitlesError.notLoggedIn) {
        _ = try await f.service.quota()
    }
}

@Test func quotaLogsInWithStoredCredentials() async throws {
    let f = try makeService(http: server(), saved: saved)
    let quota = try await f.service.quota()
    #expect(quota.remaining == 50 && quota.allowed == 100)
}

/// Inget fel från servicen (nätverk, serversvar, inloggning, lagring) innehåller användarnamn, lösenord, nyckel eller token.
@Test func serviceErrorsNeverContainSecrets() async throws {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "\(userName) \(passWord) \(apiKey)" }
    }
    let secrets = [userName, passWord, apiKey, "tok-abc"]
    let servers: [MockHTTP] = [
        MockHTTP { _ in throw Boom() },
        MockHTTP { _ in (Data("\(userName)\(passWord)\(apiKey)".utf8), 500, [:]) },
        MockHTTP { _ in (Data("nope".utf8), 200, [:]) },
        MockHTTP { _ in (Data(), 401, [:]) },
    ]
    for http in servers {
        let f = try makeService(http: http, saved: saved)
        var errors: [any Error] = []
        do { _ = try await f.service.login(username: userName, password: passWord) } catch { errors.append(error) }
        do { _ = try await f.service.download(osResult(1), for: subtitleKey()) } catch { errors.append(error) }
        do { _ = try await f.service.quota() } catch { errors.append(error) }
        do { _ = try await f.service.search(OpenSubtitlesQuery(tmdbID: 1), preferredLanguages: []) } catch {
            errors.append(error)
        }
        #expect(!errors.isEmpty)
        for error in errors {
            let text = "\(error) \(String(reflecting: error)) \(String(describing: error)) \(error.localizedDescription)"
            for secret in secrets { #expect(!text.contains(secret)) }
        }
    }
}
