#if !os(tvOS)
import Core
import Downloads
import Foundation
import GRDB
import Library
import Metadata
import PlaybackCore
import Providers
import ProvidersTestSupport
import Subtitles
import Testing
@testable import IPTVApp

// MARK: - Fakes

private final class APITransport: DownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedRequests: [DownloadTransportRequest] = []
    let events: AsyncStream<DownloadTransportEvent>

    init() {
        events = AsyncStream<DownloadTransportEvent>.makeStream().stream
    }

    var started: [DownloadTransportRequest] { lock.withLock { startedRequests } }

    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        lock.withLock {
            startedRequests.append(request)
            return DownloadTaskHandle(key: request.key, taskID: startedRequests.count)
        }
    }

    func pause(_ handle: DownloadTaskHandle) async -> Data? { nil }
    func cancel(_ handle: DownloadTaskHandle) async {}
    func reattach() async -> [DownloadTaskHandle] { [] }
}

private final class APINetwork: NetworkPolicy, @unchecked Sendable {
    let status = NetworkStatus(isOnline: true, isOnWifi: true)
    var changes: AsyncStream<NetworkStatus> { AsyncStream { $0.yield(status) } }
}

/// Xtream-svar ur fixturerna; bilder (`.jpg`) svarar med bytes, eller kastar fel när `failImages` är satt.
private final class ImageHTTP: HTTPClient, @unchecked Sendable {
    private let inner = StubHTTPClient(fixtures: standardFixtures)
    private let lock = NSLock()
    private var imageRequests: [URL] = []
    let failImages: Bool

    init(failImages: Bool = false) { self.failImages = failImages }

    var requestedImages: [URL] { lock.withLock { imageRequests } }

    func get(_ url: URL) async throws -> (Data, Int) {
        guard url.pathExtension == "jpg" else { return try await inner.get(url) }
        lock.withLock { imageRequests.append(url) }
        if failImages { throw URLError(.notConnectedToInternet) }
        return (Data("image-bytes".utf8), 200)
    }
}

// MARK: - Uppsättning

@MainActor
private struct Setup {
    let model: AppModel
    let playlistID: UUID
    let store: DownloadStore
    let transport: APITransport
    let subtitles: SubtitleStore
    let db: AppDatabase
    let root: URL

    var manager: DownloadManager { model.downloadManager! }

    func movieKey(_ id: String = "101") -> DownloadKey {
        DownloadKey(profileID: model.activeProfile!.profile.id, playlistID: playlistID, kind: .movie, providerID: id)
    }

    func episodeKey(_ id: String) -> DownloadKey {
        DownloadKey(profileID: model.activeProfile!.profile.id, playlistID: playlistID, kind: .series, providerID: id)
    }

    var seriesOrder: [String] { manager.items.filter { $0.key.kind == .series }.map(\.key.providerID) }
}

/// Modell med en importerad Xtream-spellista, nedladdningshanterare med fakes och (om `enter`) vald vuxenprofil.
@MainActor
private func makeSetup(http: HTTPClient = ImageHTTP(), userState: UserStateStore = InMemoryUserStateStore(),
                       enter: Bool = true) async throws -> Setup {
    let db = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("download-api-tests-\(UUID().uuidString)", isDirectory: true)
    let subtitles = SubtitleStore(db: db, directory: root.appendingPathComponent("subtitles", isDirectory: true))
    let model = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(), http: http,
                         defaults: freshDefaults(), userState: userState, subtitleStore: subtitles)
    await model.addPlaylist(name: "Min", secret: xtreamSecret)
    let playlistID = try #require(model.playlists.first?.id)
    let store = DownloadStore(db: db, directory: root.appendingPathComponent("store", isDirectory: true))
    let transport = APITransport()
    model.attachDownloads(store: store, transport: transport, network: APINetwork(), freeSpace: { 100_000_000_000 })
    await model.downloadManager?.start()
    if enter { model.enter(playlistID: playlistID) }
    return Setup(model: model, playlistID: playlistID, store: store, transport: transport, subtitles: subtitles,
                 db: db, root: root)
}

private func progress(_ playlist: UUID, episode id: String, watched: Bool, at time: TimeInterval) -> WatchProgress {
    WatchProgress(key: ProgressKey(playlistID: playlist, kind: .series, providerID: id, seriesProviderID: "5"),
                  position: 100, duration: 1000, watched: watched, updatedAt: Date(timeIntervalSince1970: time))
}

// MARK: - Tester

@MainActor
struct DownloadAPITests {
    @Test func kidsProfileCannotDownloadAnything() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let m = s.model
        // En vuxen har en rad; barnprofilen får varken se den eller röra den.
        try await m.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let adultKey = s.movieKey()
        let kid = try m.addProfile(playlistID: s.playlistID, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: kid, pin: nil)
        let before = m.downloadManager?.items.count

        #expect(!m.downloadsAvailable)
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadMovie(providerID: "102", playlistID: s.playlistID)
        }
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadEpisode(providerID: "501", seriesProviderID: "5", playlistID: s.playlistID)
        }
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadSeason(1, seriesProviderID: "5", playlistID: s.playlistID)
        }
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadNextEpisodes(count: 3, seriesProviderID: "5", after: nil, playlistID: s.playlistID)
        }
        #expect(m.downloadState(for: adultKey) == nil)
        await m.removeDownload(adultKey)
        #expect(m.downloadManager?.items.count == before)
        #expect(m.downloadManager?.items.contains { $0.key == adultKey } == true)
        #expect(!(m.downloadManager?.items.contains { $0.key.providerID == "102" } ?? true))
    }

    @Test func noProfileIsKids() async throws {
        let s = try await makeSetup(enter: false)
        defer { try? FileManager.default.removeItem(at: s.root) }
        let m = s.model
        #expect(m.activeProfile == nil)
        #expect(!m.downloadsAvailable)
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadMovie(providerID: "101", playlistID: s.playlistID)
        }
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await m.downloadSeason(1, seriesProviderID: "5", playlistID: s.playlistID)
        }
        #expect(m.downloadState(for: DownloadKey(profileID: UUID(), playlistID: s.playlistID, kind: .movie,
                                                 providerID: "101")) == nil)
        #expect(m.downloadManager?.items.isEmpty == true)
        #expect(s.transport.started.isEmpty)
    }

    @Test func downloadMovieStoresSnapshotAndEnqueues() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let key = s.movieKey()
        #expect(s.model.downloadState(for: key) != nil)
        let stored = try #require(try s.store.download(for: key))
        #expect(stored.snapshot.title == "Fake Movie One")
        #expect(stored.snapshot.year == 2021)
        #expect(stored.snapshot.container == "mkv")
        #expect(stored.snapshot.locator == .xtream(kind: .movie, streamID: "101", container: "mkv"))
        #expect(stored.snapshot.seriesProviderID == nil)
    }

    @Test func seasonPlansOnlyMissingEpisodesInOrder() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadEpisode(providerID: "502", seriesProviderID: "5", playlistID: s.playlistID)
        #expect(s.seriesOrder == ["502"])
        try await s.model.downloadSeason(1, seriesProviderID: "5", playlistID: s.playlistID)
        // 502 fanns redan: bara 501 läggs till. Säsong 2 rörs inte.
        #expect(s.seriesOrder == ["502", "501"])
        try await s.model.downloadSeason(1, seriesProviderID: "5", playlistID: s.playlistID)
        #expect(s.seriesOrder == ["502", "501"])
        let first = try #require(try s.store.download(for: s.episodeKey("501")))
        #expect(first.snapshot.season == 1)
        #expect(first.snapshot.episode == 1)
        #expect(first.snapshot.seriesProviderID == "5")
        #expect(first.snapshot.seriesTitle == "Fake Series")
        #expect(first.snapshot.container == "mkv")
    }

    @Test func nextThreeUsesLastWatchedWhenNoAnchor() async throws {
        let state = InMemoryUserStateStore()
        let s = try await makeSetup(userState: state)
        defer { try? FileManager.default.removeItem(at: s.root) }
        state.save(progress(s.playlistID, episode: "501", watched: true, at: 10))
        state.save(progress(s.playlistID, episode: "502", watched: true, at: 20))
        try await s.model.downloadNextEpisodes(count: 3, seriesProviderID: "5", after: nil, playlistID: s.playlistID)
        // Senast sedd är 502: bara 503 återstår, över säsongsgränsen.
        #expect(s.seriesOrder == ["503"])

        let fresh = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        try await fresh.model.downloadNextEpisodes(count: 2, seriesProviderID: "5", after: nil,
                                                   playlistID: fresh.playlistID)
        #expect(fresh.seriesOrder == ["501", "502"])
        try await fresh.model.downloadNextEpisodes(count: 3, seriesProviderID: "5", after: "501",
                                                   playlistID: fresh.playlistID)
        #expect(fresh.seriesOrder == ["501", "502", "503"])
    }

    @Test func snapshotKeepsDataAfterCatalogDelete() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        try await s.model.downloadEpisode(providerID: "501", seriesProviderID: "5", playlistID: s.playlistID)
        try await s.db.writer.write {
            try $0.execute(sql: "DELETE FROM movie")
            try $0.execute(sql: "DELETE FROM episode")
            try $0.execute(sql: "DELETE FROM series")
        }
        let movie = try #require(try s.store.download(for: s.movieKey()))
        #expect(movie.snapshot.title == "Fake Movie One")
        let episode = try #require(try s.store.download(for: s.episodeKey("501")))
        #expect(episode.snapshot.seriesTitle == "Fake Series")
        #expect(episode.snapshot.title == "Pilot")
        #expect(try s.store.list(profileID: s.model.activeProfile!.profile.id, playlistID: s.playlistID).count == 2)
    }

    @Test func artworkIsSavedLocallyAndPrefersTMDB() async throws {
        let http = ImageHTTP()
        let s = try await makeSetup(http: http)
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.model.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "Fake", posterPath: "/poster.jpg",
                          backdropPath: "/back.jpg", language: "sv-SE"), now: Date())
        try s.model.metadataStore.saveMatch(playlistID: s.playlistID, kind: .movie, providerID: "101", tmdbID: 12345,
                                            confidence: 1, now: Date())
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let key = s.movieKey()
        #expect(http.requestedImages.allSatisfy { $0.host == "image.tmdb.org" })
        #expect(http.requestedImages.count == 2)
        let stored = try #require(try s.store.download(for: key))
        #expect(stored.artworkURLs.poster != nil)
        #expect(stored.artworkURLs.backdrop != nil)
        #expect(stored.artworkURLs.still == nil)
        // Hanteraren pekar på filerna utan omstart.
        #expect(s.model.downloadedArtworkURL(for: key, kind: .poster) == stored.artworkURLs.poster)
    }

    @Test func providerPosterUsedWithoutMetadata() async throws {
        let http = ImageHTTP()
        let s = try await makeSetup(http: http)
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        #expect(http.requestedImages.map(\.host) == ["example.invalid"])
        #expect(try s.store.download(for: s.movieKey())?.artworkURLs.poster != nil)
    }

    @Test func artworkFailureDoesNotFailDownload() async throws {
        let s = try await makeSetup(http: ImageHTTP(failImages: true))
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let key = s.movieKey()
        #expect(s.model.downloadState(for: key) != nil)
        let stored = try #require(try s.store.download(for: key))
        #expect(stored.artworkURLs.poster == nil)
        #expect(stored.snapshot.title == "Fake Movie One")
    }

    @Test func removeKeepsSubtitles() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let key = s.movieKey()
        // Offline-nyckeln är samma tupel som undertexternas nyckel.
        let subtitleKey = SubtitleKey(profileID: key.profileID, playlistID: key.playlistID, kind: key.kind,
                                      providerID: key.providerID)
        let request = try await s.model.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                        playlistID: s.playlistID)
        #expect(s.model.subtitleKey(for: request, playlistID: s.playlistID) == subtitleKey)
        let result = OpenSubtitlesResult(id: 11, language: "sv", release: "Rel", fileName: "a.srt", rating: 1,
                                         downloadCount: 1, hearingImpaired: false, aiTranslated: false)
        _ = try s.subtitles.save(Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8), result: result,
                                 for: subtitleKey)

        await s.model.removeDownload(key)
        #expect(s.model.downloadState(for: key) == nil)
        #expect(try s.store.download(for: key) == nil)
        #expect(try s.subtitles.list(for: subtitleKey).count == 1)
    }

    @Test func downloadStateReflectsManager() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let key = s.movieKey()
        #expect(s.model.downloadState(for: key) == nil)
        try await s.model.downloadMovie(providerID: "101", playlistID: s.playlistID)
        let expected = s.manager.items.first { $0.key == key }?.state
        #expect(expected != nil)
        #expect(s.model.downloadState(for: key) == expected)
        // Annan profils nyckel ger inget.
        let other = DownloadKey(profileID: UUID(), playlistID: s.playlistID, kind: .movie, providerID: "101")
        #expect(s.model.downloadState(for: other) == nil)
        await s.model.removeDownload(key)
        #expect(s.model.downloadState(for: key) == nil)
    }

    @Test func episodesFetchedLazilyForSeason() async throws {
        let http = ImageHTTP()
        let s = try await makeSetup(http: http)
        defer { try? FileManager.default.removeItem(at: s.root) }
        #expect(try s.model.store.episodes(playlistID: s.playlistID, seriesProviderID: "5").isEmpty)
        try await s.model.downloadSeason(2, seriesProviderID: "5", playlistID: s.playlistID)
        #expect(s.seriesOrder == ["503"])
        #expect(try s.model.store.episodes(playlistID: s.playlistID, seriesProviderID: "5").count == 3)
    }

    @Test func playlistOfOtherProfileIsNotAllowed() async throws {
        let s = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await s.model.downloadMovie(providerID: "101", playlistID: UUID())
        }
        await #expect(throws: DownloadAPIError.notFound) {
            try await s.model.downloadMovie(providerID: "nope", playlistID: s.playlistID)
        }
    }
}
#endif
