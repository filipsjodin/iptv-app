import Core
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Subtitles
import Testing
@testable import IPTVApp

private let osKey = "fake-os-key-123456"
private let osUser = "fake-user-xyz"
private let osPass = "fake-pass-qrs"

/// OpenSubtitles-anrop räknas och besvaras av testet (inloggning lyckas eller nekas); allt annat går till
/// leverantörens fixtures.
private final class OSHTTP: HTTPClient, @unchecked Sendable {
    private let inner = StubHTTPClient(fixtures: standardFixtures)
    private let lock = NSLock()
    private var calls = 0
    let loginStatus: Int

    init(loginStatus: Int = 401) { self.loginStatus = loginStatus }

    /// Antal anrop mot OpenSubtitles.
    var osCalls: Int { lock.withLock { calls } }

    private func isOS(_ url: URL) -> Bool { url.host?.contains("opensubtitles") == true }
    private func record() { lock.withLock { calls += 1 } }

    func get(_ url: URL) async throws -> (Data, Int) {
        if isOS(url) { record(); return (Data(), 404) }
        return try await inner.get(url)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        if isOS(url) { record(); return (Data("{\"data\":[]}".utf8), 200, [:]) }
        return try await inner.get(url, headers: headers)
    }

    func download(_ url: URL) async throws -> (file: URL, status: Int) {
        if isOS(url) { record(); return (url, 404) }
        return try await inner.download(url)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int, [String: String]) {
        guard isOS(url) else { return try await inner.post(url, headers: headers, body: body) }
        record()
        let json = #"{"token":"fake-token","user":{"allowed_downloads":100,"remaining_downloads":97}}"#
        return (Data(json.utf8), loginStatus, [:])
    }
}

@MainActor
private func subtitleModel(http: OSHTTP = OSHTTP(), key: String? = osKey, withStore: Bool = true,
                           credentials: InMemoryOpenSubtitlesCredentialStore = InMemoryOpenSubtitlesCredentialStore())
    async throws -> (AppModel, UUID)
{
    let db = try AppDatabase.inMemory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-tests-\(UUID().uuidString)")
    let m = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(), http: http,
                     defaults: freshDefaults(), openSubtitlesKey: key,
                     subtitleStore: withStore ? SubtitleStore(db: db, directory: dir) : nil,
                     subtitleCredentials: credentials)
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    return (m, try #require(m.playlists.first?.id))
}

private func movieRequest(_ playlistID: UUID, providerID: String = "101", title: String = "Barnfilm") -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: providerID), title: title,
                    locator: .xtream(kind: .movie, streamID: providerID, container: "mp4"), container: "mp4",
                    isLive: false)
}

private let result = OpenSubtitlesResult(id: 11, language: "sv", release: "Rel", fileName: "a.srt", rating: 1,
                                         downloadCount: 1, hearingImpaired: false, aiTranslated: false)

@MainActor
struct SubtitleModelTests {
    @Test func kidsProfileGetsNoSearchNoDownloadNoLogin() async throws {
        let http = OSHTTP(loginStatus: 200)
        let creds = InMemoryOpenSubtitlesCredentialStore()
        let (m, id) = try await subtitleModel(http: http, credentials: creds)
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: kid, pin: nil)
        try #require(m.kidsRestricted)
        let request = movieRequest(id)

        #expect(!m.subtitlesAvailable)
        #expect(m.subtitleKey(for: request, playlistID: id) == nil)
        await #expect(throws: SubtitleAccessError.notAllowed) {
            _ = try await m.searchSubtitles(for: request, playlistID: id, languages: ["sv"])
        }
        await #expect(throws: SubtitleAccessError.notAllowed) {
            _ = try await m.downloadSubtitle(result, for: request, playlistID: id)
        }
        await #expect(throws: SubtitleAccessError.notAllowed) {
            _ = try await m.openSubtitlesLogin(username: osUser, password: osPass)
        }
        #expect(throws: SubtitleAccessError.notAllowed) { try m.openSubtitlesLogout() }
        #expect(await m.openSubtitlesQuota() == nil)
        let stored = await m.storedSubtitles(for: request, playlistID: id)
        #expect(stored.subs.isEmpty && stored.offset == 0)
        await m.setSubtitleOffset(2, for: request, playlistID: id)
        await m.refreshOpenSubtitlesStatus()
        #expect(!m.openSubtitlesLoggedIn)
        #expect(http.osCalls == 0)
        #expect(try creds.load() == nil)
    }

    @Test func noActiveProfileIsTreatedAsKids() async throws {
        let http = OSHTTP(loginStatus: 200)
        let (m, id) = try await subtitleModel(http: http)
        #expect(m.activeProfile == nil && m.kidsRestricted)
        let request = movieRequest(id)
        #expect(!m.subtitlesAvailable)
        #expect(m.subtitleKey(for: request, playlistID: id) == nil)
        await #expect(throws: SubtitleAccessError.notAllowed) {
            _ = try await m.searchSubtitles(for: request, playlistID: id, languages: ["sv"])
        }
        await #expect(throws: SubtitleAccessError.notAllowed) {
            _ = try await m.openSubtitlesLogin(username: osUser, password: osPass)
        }
        #expect(await m.openSubtitlesQuota() == nil)
        #expect(http.osCalls == 0)
    }

    @Test func missingAPIKeyDisablesFeature() async throws {
        let http = OSHTTP(loginStatus: 200)
        let (m, id) = try await subtitleModel(http: http, key: "$(OPENSUBTITLES_API_KEY)")
        m.enter(playlistID: id)
        try #require(m.activeProfile != nil && !m.kidsRestricted)
        #expect(!m.openSubtitlesConfigured)
        #expect(!m.subtitlesAvailable)
        await #expect(throws: SubtitleAccessError.featureDisabled) {
            _ = try await m.searchSubtitles(for: movieRequest(id), playlistID: id, languages: ["sv"])
        }
        await #expect(throws: SubtitleAccessError.featureDisabled) {
            _ = try await m.openSubtitlesLogin(username: osUser, password: osPass)
        }
        #expect(await m.openSubtitlesQuota() == nil)
        #expect(http.osCalls == 0)
        let (empty, _) = try await subtitleModel(key: "  ")
        #expect(!empty.openSubtitlesConfigured)
    }

    @Test func adultProfileWithKeyIsAvailable() async throws {
        let (m, id) = try await subtitleModel()
        m.enter(playlistID: id)
        try #require(m.activeProfile != nil && !m.kidsRestricted)
        #expect(m.openSubtitlesConfigured && m.subtitlesAvailable)
        let key = try #require(m.subtitleKey(for: movieRequest(id), playlistID: id))
        #expect(key.kind == .movie && key.providerID == "101" && key.playlistID == id)
        #expect(key.profileID == m.activeProfile?.profile.id)
        let live = PlaybackRequest(key: ProgressKey(playlistID: id, kind: .live, providerID: "1"), title: "K",
                                   locator: .xtream(kind: .live, streamID: "1", container: "ts"), container: nil,
                                   isLive: true)
        #expect(m.subtitleKey(for: live, playlistID: id) == nil)
    }

    @Test func queryUsesTmdbAndEpisodeNumbers() {
        let meta = TitleMetadata(tmdbID: 4242, kind: .series, title: "Serie", imdbID: "tt0903747", language: "sv-SE")
        let q = AppModel.subtitleQuery(metadata: meta, title: "Ignoreras", year: 2019, season: 2, episode: 5,
                                       languages: ["sv", "en"])
        #expect(q == OpenSubtitlesQuery(tmdbID: 4242, imdbID: "tt0903747", season: 2, episode: 5,
                                        languages: ["sv", "en"]))
        let movie = TitleMetadata(tmdbID: 7, kind: .movie, title: "Film", imdbID: " ", language: "sv-SE")
        let mq = AppModel.subtitleQuery(metadata: movie, title: nil, year: nil, season: nil, episode: nil,
                                        languages: [])
        #expect(mq?.tmdbID == 7 && mq?.imdbID == nil && mq?.season == nil && mq?.title == nil)
    }

    @Test func queryFallsBackToTitleYear() {
        let q = AppModel.subtitleQuery(metadata: nil, title: "  Fake Series ", year: 2019, season: 1, episode: 3,
                                       languages: ["sv"])
        #expect(q == OpenSubtitlesQuery(season: 1, episode: 3, title: "Fake Series", year: 2019, languages: ["sv"]))
        #expect(AppModel.subtitleQuery(metadata: nil, title: " ", year: nil, season: nil, episode: nil,
                                       languages: []) == nil)
        #expect(AppModel.subtitleQuery(metadata: nil, title: nil, year: 2000, season: nil, episode: nil,
                                       languages: []) == nil)
    }

    @Test func queryForEpisodeAndMovieComesFromTheLibrary() async throws {
        let (m, id) = try await subtitleModel()
        m.enter(playlistID: id)
        try #require(m.activeProfile != nil && !m.kidsRestricted)
        try m.store.upsertEpisodes(
            [Episode(providerID: "e9", seriesProviderID: "5", season: 2, number: 4, title: "E",
                     locator: .xtream(kind: .series, streamID: "e9", container: "mp4"))],
            seriesProviderID: "5", playlistID: id, now: Date())
        let episodeRequest = PlaybackRequest(
            key: ProgressKey(playlistID: id, kind: .series, providerID: "e9", seriesProviderID: "5"), title: "E",
            locator: .xtream(kind: .series, streamID: "e9", container: "mp4"), container: "mp4", isLive: false)
        let eq = try #require(await m.subtitleQuery(for: episodeRequest, playlistID: id, languages: ["sv"]))
        #expect(eq.season == 2 && eq.episode == 4)
        #expect(eq.title == "Fake Series" && eq.year == 2019)

        let movie = try #require(try m.store.movie(playlistID: id, providerID: "101"))
        let mq = try #require(await m.subtitleQuery(for: movieRequest(id), playlistID: id, languages: []))
        #expect(mq.title == movie.title && mq.season == nil && mq.episode == nil)

        let unknown = PlaybackRequest(
            key: ProgressKey(playlistID: id, kind: .series, providerID: "nope", seriesProviderID: "5"), title: "X",
            locator: .xtream(kind: .series, streamID: "nope", container: "mp4"), container: nil, isLive: false)
        #expect(await m.subtitleQuery(for: unknown, playlistID: id, languages: []) == nil)
    }

    @Test func loginFailureKeepsLoggedOutAndKeychainEmpty() async throws {
        let http = OSHTTP(loginStatus: 401)
        let creds = InMemoryOpenSubtitlesCredentialStore()
        let (m, id) = try await subtitleModel(http: http, credentials: creds)
        m.enter(playlistID: id)
        do {
            _ = try await m.openSubtitlesLogin(username: osUser, password: osPass)
            Issue.record("Inloggningen skulle ha misslyckats")
        } catch {
            #expect(error as? OpenSubtitlesError == .invalidCredentials)
            let text = "\(error) \(String(reflecting: error))"
            #expect(!text.contains(osUser) && !text.contains(osPass) && !text.contains(osKey))
        }
        #expect(!m.openSubtitlesLoggedIn)
        #expect(try creds.load() == nil)
        #expect(http.osCalls == 1)
    }

    @Test func loginSavesCredentialsAndLogoutClearsThem() async throws {
        let creds = InMemoryOpenSubtitlesCredentialStore()
        let (m, id) = try await subtitleModel(http: OSHTTP(loginStatus: 200), credentials: creds)
        m.enter(playlistID: id)
        let quota = try await m.openSubtitlesLogin(username: osUser, password: osPass)
        #expect(quota.remaining == 97 && quota.allowed == 100)
        #expect(m.openSubtitlesLoggedIn)
        #expect(try creds.load() == OpenSubtitlesCredentials(username: osUser, password: osPass))
        try m.openSubtitlesLogout()
        #expect(!m.openSubtitlesLoggedIn)
        #expect(try creds.load() == nil)
    }

    @Test func credentialsNeverInStateDescriptions() async throws {
        let creds = InMemoryOpenSubtitlesCredentialStore()
        let (m, id) = try await subtitleModel(http: OSHTTP(loginStatus: 200), credentials: creds)
        m.enter(playlistID: id)
        _ = try await m.openSubtitlesLogin(username: osUser, password: osPass)
        let loaded = try creds.load()
        var dumped = ""
        dump(m.subtitleService as Any, to: &dumped)
        dump(loaded as Any, to: &dumped)
        dump(m.subtitleCredentials, to: &dumped)
        let texts = [dumped, String(describing: m.subtitleService as Any), String(describing: loaded as Any),
                     String(reflecting: loaded as Any)]
        for text in texts {
            #expect(!text.contains(osUser) && !text.contains(osPass) && !text.contains(osKey))
        }
    }

    @Test func storedSubtitlesAndOffsetRoundTrip() async throws {
        let (m, id) = try await subtitleModel()
        m.enter(playlistID: id)
        let request = movieRequest(id)
        let before = await m.storedSubtitles(for: request, playlistID: id)
        #expect(before.subs.isEmpty && before.offset == 0)
        await m.setSubtitleOffset(1.5, for: request, playlistID: id)
        #expect(await m.storedSubtitles(for: request, playlistID: id).offset == 1.5)
        await m.setSubtitleOffset(10_000, for: request, playlistID: id)
        #expect(await m.storedSubtitles(for: request, playlistID: id).offset == SubtitleTrack.maxOffset)
    }
}
