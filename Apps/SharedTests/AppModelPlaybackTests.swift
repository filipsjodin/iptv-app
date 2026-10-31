import Core
import Foundation
import Library
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

/// Fördröjer `get_series_info` så att två samtidiga anrop garanterat överlappar.
private struct SlowSeriesInfoHTTP: HTTPClient {
    let inner: StubHTTPClient
    func get(_ url: URL) async throws -> (Data, Int) {
        if url.query?.contains("get_series_info") == true { try await Task.sleep(for: .milliseconds(200)) }
        return try await inner.get(url)
    }
}

@MainActor
private func importedModel(http: HTTPClient? = nil, creds: CredentialStore = InMemoryCredentialStore(),
                           userState: UserStateStore = InMemoryUserStateStore(),
                           defaults: UserDefaults = freshDefaults()) async throws -> (AppModel, UUID) {
    let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: creds,
                     http: http ?? StubHTTPClient(fixtures: standardFixtures), defaults: defaults,
                     userState: userState)
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    try #require(m.playlists.count == 1)
    return (m, m.playlists[0].id)
}

private func ep(_ id: String, season: Int, number: Int) -> Episode {
    Episode(providerID: id, seriesProviderID: "s", season: season, number: number, title: id,
            locator: .xtream(kind: .series, streamID: id, container: "mp4"))
}

@MainActor
struct AppModelPlaybackTests {
    @Test func xtreamEpisodesFetchedLazilyAndCached() async throws {
        let http = StubHTTPClient(fixtures: standardFixtures)
        let (m, id) = try await importedModel(http: http)
        let before = http.requestCount(action: "get_series_info")
        let first = try await m.episodes(for: "5", playlistID: id)
        #expect(first.map(\.providerID) == ["501", "502", "503"])
        #expect(http.requestCount(action: "get_series_info") == before + 1)
        let second = try await m.episodes(for: "5", playlistID: id)
        #expect(second.map(\.providerID) == ["501", "502", "503"])
        #expect(http.requestCount(action: "get_series_info") == before + 1)
        #expect(try m.store.episodes(playlistID: id, seriesProviderID: "5").count == 3)
    }

    @Test func concurrentEpisodeLoadsShareOneFetch() async throws {
        let stub = StubHTTPClient(fixtures: standardFixtures)
        let (m, id) = try await importedModel(http: SlowSeriesInfoHTTP(inner: stub))
        let before = stub.requestCount(action: "get_series_info")
        async let a = m.episodes(for: "5", playlistID: id)
        async let b = m.episodes(for: "5", playlistID: id)
        let (ra, rb) = try await (a, b)
        #expect(ra.count == 3)
        #expect(rb.count == 3)
        #expect(stub.requestCount(action: "get_series_info") == before + 1)
    }

    @Test func m3uWithoutEpisodesGivesEmptyList() async throws {
        let store = LibraryStore(db: try .inMemory())
        let p = Playlist(name: "M", kind: .m3u)
        try store.upsertPlaylist(p)
        let creds = InMemoryCredentialStore()
        try creds.save(.m3u(url: URL(string: "http://h/list.m3u")!, epgURL: nil), for: p.id)
        let m = AppModel(store: store, credentials: creds, http: StubHTTPClient(fixtures: standardFixtures),
                         defaults: freshDefaults(), userState: InMemoryUserStateStore())
        #expect(try await m.episodes(for: "x", playlistID: p.id).isEmpty)
    }

    @Test func playbackRequestUsesResume() async throws {
        let state = InMemoryUserStateStore()
        let (m, id) = try await importedModel(userState: state)
        let key = ProgressKey(playlistID: id, kind: .movie, providerID: "101")
        state.save(WatchProgress(key: key, position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let request = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                  playlistID: id)
        #expect(request.startAt == 600)
        #expect(request.key == key)
        #expect(request.title == "Fake Movie One")
        #expect(!request.isLive)
        let fresh = try await m.playbackRequest(kind: .movie, providerID: "102", seriesProviderID: nil,
                                                playlistID: id)
        #expect(fresh.startAt == nil)
    }

    @Test func startFromBeginningOverridesResume() async throws {
        let state = InMemoryUserStateStore()
        let (m, id) = try await importedModel(userState: state)
        let key = ProgressKey(playlistID: id, kind: .movie, providerID: "101")
        state.save(WatchProgress(key: key, position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let request = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                  playlistID: id, startFromBeginning: true)
        #expect(request.startAt == 0)

        _ = try await m.episodes(for: "5", playlistID: id)
        let epKey = ProgressKey(playlistID: id, kind: .series, providerID: "502", seriesProviderID: "5")
        state.save(WatchProgress(key: epKey, position: 120, duration: 1200, watched: false, updatedAt: Date()))
        let resumed = try await m.playbackRequest(kind: .series, providerID: "502", seriesProviderID: "5",
                                                  playlistID: id)
        #expect(resumed.startAt == 120)
        let over = try await m.playbackRequest(kind: .series, providerID: "502", seriesProviderID: "5",
                                               playlistID: id, startFromBeginning: true)
        #expect(over.startAt == 0)
    }

    @Test func continueWatchingFilteredByTab() async throws {
        let state = InMemoryUserStateStore()
        let (m, id) = try await importedModel(userState: state)
        let now = Date()
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .movie, providerID: "101"),
                                 position: 600, duration: 6000, watched: false, updatedAt: now))
        _ = try await m.episodes(for: "5", playlistID: id)
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .series, providerID: "502",
                                                  seriesProviderID: "5"),
                                 position: 120, duration: 1200, watched: false, updatedAt: now.addingTimeInterval(-10)))
        let all = await m.continueWatching(playlistID: id)
        let movies = await m.continueWatching(playlistID: id, kind: .movie)
        let episodes = await m.continueWatching(playlistID: id, kind: .series)
        #expect(all.map(\.request.key.providerID) == ["101", "502"])
        #expect(movies.map(\.request.key.providerID) == ["101"])
        #expect(episodes.map(\.request.key.providerID) == ["502"])

        let entries = state.continueWatching(playlistID: id, limit: 20)
        #expect(AppModel.continueWatchingEntries(entries, kind: .movie).allSatisfy { $0.key.kind == .movie })
        #expect(AppModel.continueWatchingEntries(entries, kind: nil).count == 2)
    }

    @Test func continueWatchingSkipsVanishedTitles() async throws {
        let state = InMemoryUserStateStore()
        let (m, id) = try await importedModel(userState: state)
        let now = Date()
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .movie, providerID: "x"),
                                 position: 600, duration: 6000, watched: false, updatedAt: now))
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .movie, providerID: "101"),
                                 position: 600, duration: 6000, watched: false, updatedAt: now.addingTimeInterval(-5)))
        _ = try await m.episodes(for: "5", playlistID: id)
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .series, providerID: "502",
                                                  seriesProviderID: "5"),
                                 position: 120, duration: 1200, watched: false, updatedAt: now.addingTimeInterval(-10)))
        let items = await m.continueWatching(playlistID: id)
        #expect(items.map(\.request.key.providerID) == ["101", "502"])
        #expect(items.first?.title == "Fake Movie One")
        #expect(items.first?.subtitle == nil)
        #expect(items.first?.request.startAt == 600)
        #expect(abs((items.first?.progressFraction ?? 0) - 0.1) < 0.0001)
        #expect(items.last?.subtitle == "S1:E2")
        #expect(items.last?.title == "Fake Series")
    }

    @Test func orphanKeychainEntriesSweptOnLoad() async throws {
        let defaults = freshDefaults()
        let store = LibraryStore(db: try .inMemory())
        let a = Playlist(name: "A", kind: .xtream)
        let c = Playlist(name: "C", kind: .xtream)   // bara i databasen (före metadata) – behålls
        try store.upsertPlaylist(a)
        try store.upsertPlaylist(c)
        PlaylistMetadataStore(defaults: defaults).save(a)
        let creds = SpyCredentialStore()
        let b = UUID()
        try creds.save(xtreamSecret, for: a.id)
        try creds.save(xtreamSecret, for: b)
        try creds.save(xtreamSecret, for: c.id)
        let m = AppModel(store: store, credentials: creds, http: StubHTTPClient(fixtures: standardFixtures),
                         defaults: defaults, userState: InMemoryUserStateStore())
        await m.load()
        #expect(Set(creds.savedIDs) == [a.id, c.id])
        #expect(creds.deleted == [b])
    }

    @Test func sweepSkippedOnFallbackDatabase() async throws {
        let defaults = freshDefaults()
        let creds = SpyCredentialStore()
        let orphan = UUID()
        try creds.save(xtreamSecret, for: orphan)
        let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: creds,
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults,
                         userState: InMemoryUserStateStore(), usesFallbackDatabase: true)
        await m.load()
        #expect(creds.deleted.isEmpty)
        #expect(creds.savedIDs == [orphan])
    }

    @Test func removeClearsUserState() async throws {
        let state = InMemoryUserStateStore()
        let (m, id) = try await importedModel(userState: state)
        state.save(WatchProgress(key: ProgressKey(playlistID: id, kind: .movie, providerID: "101"),
                                 position: 600, duration: 6000, watched: false, updatedAt: Date()))
        #expect(await m.continueWatching(playlistID: id).count == 1)
        await m.remove(id)
        #expect(await m.continueWatching(playlistID: id).isEmpty)
        #expect(state.continueWatching(playlistID: id, limit: 10).isEmpty)
    }

    @Test func liveRequestPrefersBestVariant() throws {
        let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         userState: InMemoryUserStateStore())
        let id = UUID()
        func stream(_ pid: String, _ name: String) -> LiveStream {
            LiveStream(providerID: pid, name: name, locator: .xtream(kind: .live, streamID: pid, container: "ts"))
        }
        let groups = ChannelGrouper.group([stream("1", "SVT1 HD"), stream("2", "SVT1 FHD"),
                                           stream("3", "SVT1 4K HDR")])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        let hdr = m.liveRequest(group: group, playlistID: id, displaySupportsHDR: true)
        #expect(hdr.locator == .xtream(kind: .live, streamID: "3", container: "ts"))
        #expect(hdr.isLive)
        #expect(hdr.startAt == nil)
        #expect(hdr.key == ProgressKey(playlistID: id, kind: .live, providerID: "3"))
        let sdr = m.liveRequest(group: group, playlistID: id, displaySupportsHDR: false)
        #expect(sdr.locator == .xtream(kind: .live, streamID: "2", container: "ts"))
    }

    // Inställningarna sparas per profil: se ProfileSessionTests.settingsPersistPerProfile.

    @Test func injectedUserStateIsUsed() throws {
        let state = InMemoryUserStateStore()
        let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         userState: state)
        let key = ProgressKey(playlistID: UUID(), kind: .movie, providerID: "m")
        state.save(WatchProgress(key: key, position: 100, duration: 1000, watched: false, updatedAt: Date()))
        #expect(m.userState.progress(for: key)?.position == 100)
    }

    // MARK: - Nästa avsnitt (beslut 1)

    @Test func nextEpisodeProviderOnlyForEpisodes() async throws {
        let (m, id) = try await importedModel()
        let movie = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                playlistID: id)
        let movieHasProvider = m.nextEpisodeProvider(for: movie) != nil
        #expect(!movieHasProvider)
        let groups = try m.store.channelGroups(playlistID: id)
        let group = try #require(groups.first)
        let liveHasProvider = m.nextEpisodeProvider(for: m.liveRequest(group: group, playlistID: id,
                                                                       displaySupportsHDR: false)) != nil
        #expect(!liveHasProvider)

        let first = try await m.playbackRequest(kind: .series, providerID: "501", seriesProviderID: "5",
                                                playlistID: id)
        #expect(first.key.seriesProviderID == "5")
        guard let provider = m.nextEpisodeProvider(for: first) else {
            Issue.record("avsnitt ska få en nästa-avsnitt-leverantör")
            return
        }
        let second = await provider()
        #expect(second?.key == ProgressKey(playlistID: id, kind: .series, providerID: "502", seriesProviderID: "5"))
        #expect(second?.startAt == nil)
        let third = await provider()
        #expect(third?.key.providerID == "503")
        let fourth = await provider()
        #expect(fourth?.key == nil)
    }

    // MARK: - Fortsätt-knappen i serievyn (beslut 7)

    @Test func seriesPlayTargetFollowsLastWatched() {
        let all = [ep("a", season: 1, number: 1), ep("b", season: 1, number: 2), ep("c", season: 2, number: 1)]
        let pid = UUID()
        func progress(_ id: String, watched: Bool) -> WatchProgress {
            WatchProgress(key: ProgressKey(playlistID: pid, kind: .series, providerID: id, seriesProviderID: "s"),
                          position: watched ? 1190 : 300, duration: 1200, watched: watched, updatedAt: Date())
        }
        #expect(AppModel.seriesPlayTarget(episodes: all, last: nil) == SeriesPlayTarget(episode: all[0], isContinue: false))
        #expect(AppModel.seriesPlayTarget(episodes: all, last: progress("b", watched: false))
            == SeriesPlayTarget(episode: all[1], isContinue: true))
        #expect(AppModel.seriesPlayTarget(episodes: all, last: progress("b", watched: true))
            == SeriesPlayTarget(episode: all[2], isContinue: true))
        #expect(AppModel.seriesPlayTarget(episodes: all, last: progress("c", watched: true))
            == SeriesPlayTarget(episode: all[0], isContinue: false))
        #expect(AppModel.seriesPlayTarget(episodes: all, last: progress("gone", watched: false))
            == SeriesPlayTarget(episode: all[0], isContinue: false))
        #expect(AppModel.seriesPlayTarget(episodes: [], last: nil) == nil)
    }
}

/// `get_series_info` som kan styras mellan svar: oförändrat, med uppgifter, fel eller hängande.
private final class ControlledSeriesInfoHTTP: HTTPClient, @unchecked Sendable {
    enum Mode { case passthrough, body(String), fail, hang }
    private let lock = NSLock()
    private var _mode = Mode.passthrough
    private var _fetches = 0
    let inner = StubHTTPClient(fixtures: standardFixtures)
    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var fetches: Int { lock.withLock { _fetches } }

    func get(_ url: URL) async throws -> (Data, Int) {
        guard url.query?.contains("get_series_info") == true else { return try await inner.get(url) }
        lock.withLock { _fetches += 1 }
        switch mode {
        case .passthrough: return try await inner.get(url)
        case .body(let json): return (Data(json.utf8), 200)
        case .fail: throw URLError(.notConnectedToInternet)
        case .hang:
            try await Task.sleep(for: .seconds(5))
            throw URLError(.timedOut)
        }
    }
}

private let detailedSeriesInfo = """
{"episodes":{"1":[
  {"id":"501","episode_num":1,"title":"Ett","container_extension":"mp4","info":
    {"movie_image":"https://img.example.invalid/501.jpg","plot":"Handling.","duration_secs":2520}},
  {"id":"502","episode_num":2,"title":"Två","container_extension":"mp4","info":[]},
  {"id":"503","episode_num":3,"title":"Tre","container_extension":"mp4"}]}}
"""

/// Omhämtningen av avsnitt som lagrats före migreringen (utan stillbild, beskrivning och längd): i bakgrunden, högst
/// en gång per serie och körning, och de lagrade raderna rörs aldrig av ett misslyckande.
@MainActor
struct EpisodeDetailsRefetchTests {
    private let creds = InMemoryCredentialStore()

    /// Modell med serie 5 hämtad och sedan nollställd till "lagrad före v5".
    private func legacyModel(_ http: ControlledSeriesInfoHTTP) async throws -> (AppModel, UUID) {
        let (m, id) = try await importedModel(http: http, creds: creds)
        _ = try await m.episodes(for: "5", playlistID: id)
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        try m.store.resetEpisodeDetailsFetched(playlistID: id, seriesProviderID: "5")
        return (m, id)
    }

    /// En ny modell över samma databas efterliknar en ny appkörning (tom "försökt"-mängd).
    private func freshRun(of m: AppModel, http: HTTPClient) -> AppModel {
        AppModel(store: m.store, credentials: creds, http: http, defaults: freshDefaults())
    }

    @Test func staleRowsAreRefetchedInBackgroundOncePerRun() async throws {
        let http = ControlledSeriesInfoHTTP()
        let (old, id) = try await legacyModel(http)
        let m = freshRun(of: old, http: http)
        let before = http.fetches
        http.mode = .body(detailedSeriesInfo)
        let first = try await m.episodes(for: "5", playlistID: id)
        #expect(first.allSatisfy { $0.durationSeconds == nil })  // direkt ur databasen
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        #expect(http.fetches == before + 1)
        #expect(m.episodeDetailsRevision == 1)
        let refreshed = try await m.episodes(for: "5", playlistID: id)
        let one = refreshed.first { $0.providerID == "501" }
        #expect(one?.durationSeconds == 2520)
        #expect(one?.stillURL == URL(string: "https://img.example.invalid/501.jpg"))
        #expect(one?.overview == "Handling.")
        #expect(refreshed.first { $0.providerID == "502" }?.stillURL == nil)
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        #expect(http.fetches == before + 1)
    }

    @Test func listReturnsImmediatelyWhileProviderHangs() async throws {
        let http = ControlledSeriesInfoHTTP()
        let (old, id) = try await legacyModel(http)
        let m = freshRun(of: old, http: http)
        http.mode = .hang
        let clock = ContinuousClock()
        let start = clock.now
        let list = try await m.episodes(for: "5", playlistID: id)
        #expect(clock.now - start < .seconds(2))
        #expect(list.map(\.providerID) == ["501", "502", "503"])
    }

    @Test func failedRefetchKeepsRowsAndIsNotRepeatedInTheSameRun() async throws {
        let http = ControlledSeriesInfoHTTP()
        let (old, id) = try await legacyModel(http)
        let m = freshRun(of: old, http: http)
        http.mode = .fail
        let before = http.fetches
        let kept = try await m.episodes(for: "5", playlistID: id)
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        #expect(kept.map(\.providerID) == ["501", "502", "503"])
        #expect(http.fetches == before + 1)
        #expect(try m.store.episodes(playlistID: id, seriesProviderID: "5").count == 3)
        #expect(m.episodeDetailsRevision == 0)

        http.mode = .body(detailedSeriesInfo)
        _ = try await m.episodes(for: "5", playlistID: id)
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        #expect(http.fetches == before + 1)
    }

    @Test func emptyRefetchKeepsStoredRows() async throws {
        let http = ControlledSeriesInfoHTTP()
        let (old, id) = try await legacyModel(http)
        let m = freshRun(of: old, http: http)
        http.mode = .body(#"{"episodes":[]}"#)
        _ = try await m.episodes(for: "5", playlistID: id)
        await m.awaitDetailsRefetch(for: "5", playlistID: id)
        #expect(try m.store.episodes(playlistID: id, seriesProviderID: "5").count == 3)
        #expect(try m.store.episodesNeedDetails(playlistID: id, seriesProviderID: "5") == false)
    }
}
