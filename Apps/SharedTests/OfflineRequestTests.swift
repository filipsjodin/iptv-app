import Core
import Downloads
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

/// Modell med en importerad Xtream-spellista, en vald (vuxen) profil och ett nedladdningslager i minnet.
@MainActor
private func offlineModel(userState: UserStateStore = InMemoryUserStateStore()) async throws
    -> (AppModel, UUID, DownloadStore, URL) {
    let db = try AppDatabase.inMemory()
    let m = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                     userState: userState)
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    let id = try #require(m.playlists.first?.id)
    m.enter(playlistID: id)
    try #require(m.activeProfile?.profile.playlistID == id)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("offline-request-tests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(db: db, directory: root.appendingPathComponent("store", isDirectory: true))
    m.downloadStore = store
    return (m, id, store, root)
}

/// Film 101 är barntillåten (7 år), 103 är för vuxna (18 år), 102 saknar åldersgräns.
@MainActor
private func seedAges(_ m: AppModel, _ id: UUID) throws {
    try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm",
                                                   genres: [Genre(id: 16, name: "Animerat")],
                                                   cast: [Person(id: 500, name: "Skådis")], ageLimit: 7,
                                                   language: "sv-SE"), now: Date())
    try m.metadataStore.saveMatch(playlistID: id, kind: .movie, providerID: "103", tmdbID: 999, confidence: 1,
                                  now: Date())
    try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 999, kind: .movie, title: "Vuxenfilm",
                                                   genres: [Genre(id: 16, name: "Animerat")],
                                                   cast: [Person(id: 500, name: "Skådis")], ageLimit: 18,
                                                   language: "sv-SE"), now: Date())
    m.discovery.invalidate(playlistID: id)
}

private func writeFile(_ root: URL, name: String = "media.mkv") throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent(name)
    try Data(repeating: 7, count: 64).write(to: url)
    return url
}

private func movieDownload(profile: UUID, playlist: UUID, providerID: String, file: URL?,
                           state: DownloadState = .completed) -> StoredDownload {
    StoredDownload(key: DownloadKey(profileID: profile, playlistID: playlist, kind: .movie, providerID: providerID),
                   snapshot: DownloadSnapshot(title: "Film \(providerID)", container: "mkv",
                                              locator: .xtream(kind: .movie, streamID: providerID, container: "mkv")),
                   state: state, bytesWritten: 64, fileURL: file)
}

private func episodeDownload(profile: UUID, playlist: UUID, providerID: String, season: Int, number: Int,
                             file: URL?) -> StoredDownload {
    StoredDownload(key: DownloadKey(profileID: profile, playlistID: playlist, kind: .series, providerID: providerID),
                   snapshot: DownloadSnapshot(title: "Avsnitt", season: season, episode: number, container: "mp4",
                                              seriesProviderID: "5", seriesTitle: "Serie",
                                              locator: .xtream(kind: .series, streamID: providerID, container: "mp4")),
                   state: .completed, bytesWritten: 64, fileURL: file)
}

@MainActor
struct OfflineRequestTests {
    @Test func offlineRequestSetsLocalURLContainerAndNotLive() async throws {
        let (m, id, _, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        let file = try writeFile(root)
        let request = try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                                    file: file))
        #expect(request.localURL == file)
        #expect(request.container == "mkv")
        #expect(!request.isLive)
        #expect(request.title == "Film 101")
    }

    @Test func offlineRequestRechecksKids() async throws {
        let (m, id, _, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedAges(m, id)
        let adult = try #require(m.activeProfile?.profile.id)
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        let file = try writeFile(root)

        try await m.select(profile: kid, pin: nil)
        try #require(m.activeProfile?.profile.isKids == true)
        let kidID = kid.id
        _ = try await m.offlineRequest(for: movieDownload(profile: kidID, playlist: id, providerID: "101", file: file))
        // 18 år, okänd ålder, titeln saknas i katalogen: raden och filen finns men uppspelning nekas.
        for providerID in ["103", "102", "gone"] {
            await #expect(throws: PlaybackLookupError.notAllowed) {
                try await m.offlineRequest(for: movieDownload(profile: kidID, playlist: id, providerID: providerID,
                                                              file: file))
            }
        }
        // Avsnitt vars serie inte har godkänd ålder.
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.offlineRequest(for: episodeDownload(profile: kidID, playlist: id, providerID: "501",
                                                            season: 1, number: 1, file: file))
        }
        // En annan profils nedladdning spelas aldrig, inte ens en barntillåten titel.
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.offlineRequest(for: movieDownload(profile: adult, playlist: id, providerID: "101", file: file))
        }
    }

    @Test func offlineRequestFailsWithFixedErrorWhenFileIsGoneOrNotCompleted() async throws {
        let (m, id, _, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        let missing = root.appendingPathComponent("nope.mkv")
        await #expect(throws: OfflinePlaybackError.fileMissing) {
            try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                          file: missing))
        }
        let file = try writeFile(root)
        await #expect(throws: OfflinePlaybackError.fileMissing) {
            try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                          file: file, state: .paused(.user)))
        }
    }

    @Test func offlineRequestUsesSameProgressKeyAsOnline() async throws {
        let state = InMemoryUserStateStore()
        let (m, id, _, root) = try await offlineModel(userState: state)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        let file = try writeFile(root)

        let onlineMovie = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                      playlistID: id)
        let offlineMovie = try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id,
                                                                         providerID: "101", file: file))
        #expect(offlineMovie.key == onlineMovie.key)

        let onlineEpisode = try await m.playbackRequest(kind: .series, providerID: "501", seriesProviderID: "5",
                                                        playlistID: id)
        let offlineEpisode = try await m.offlineRequest(for: episodeDownload(profile: profile, playlist: id,
                                                                             providerID: "501", season: 1, number: 1,
                                                                             file: file))
        #expect(offlineEpisode.key == onlineEpisode.key)

        // Sparad position delas: offline startar där streamingen slutade.
        state.save(WatchProgress(key: offlineMovie.key, position: 600, duration: 6000, watched: false,
                                 updatedAt: Date()))
        let resumed = try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                                    file: file))
        #expect(resumed.startAt == 600)
    }

    @Test func offlineNextEpisodeSkipsNotDownloaded() async throws {
        let (m, id, store, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        // 501 och 503 är nedladdade; 502 ligger bara i kön.
        for (episodeID, number, done) in [("501", 1, true), ("502", 2, false), ("503", 3, true)] {
            let key = DownloadKey(profileID: profile, playlistID: id, kind: .series, providerID: episodeID)
            try store.insert(DownloadSnapshot(title: "A\(number)", season: 1, episode: number, container: "mp4",
                                              seriesProviderID: "5", seriesTitle: "Serie",
                                              locator: .xtream(kind: .series, streamID: episodeID, container: "mp4")),
                             key: key)
            if done {
                try store.completeMoving(from: try writeFile(root, name: "tmp-\(episodeID)"), for: key,
                                         expectedMinBytes: 1)
            }
        }
        let first = try #require(try store.download(for: DownloadKey(profileID: profile, playlistID: id,
                                                                     kind: .series, providerID: "501")))
        let current = try await m.offlineRequest(for: first)
        let provider = try #require(m.offlineNextEpisodeProvider(for: current))
        let next = try #require(await provider())
        #expect(next.key.providerID == "503")
        #expect(next.localURL != nil)
        #expect(next.startAt == nil)
    }

    @Test func offlineNextEpisodeNilAtEnd() async throws {
        let (m, id, store, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        let key = DownloadKey(profileID: profile, playlistID: id, kind: .series, providerID: "503")
        try store.insert(DownloadSnapshot(title: "A3", season: 1, episode: 3, container: "mp4", seriesProviderID: "5",
                                          locator: .xtream(kind: .series, streamID: "503", container: "mp4")),
                         key: key)
        try store.completeMoving(from: try writeFile(root, name: "tmp"), for: key, expectedMinBytes: 1)
        let last = try #require(try store.download(for: key))
        let current = try await m.offlineRequest(for: last)
        let provider = try #require(m.offlineNextEpisodeProvider(for: current))
        #expect(await provider() == nil)

        // Filmer får ingen leverantör.
        let movie = try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                                  file: try writeFile(root, name: "m.mkv")))
        #expect(m.offlineNextEpisodeProvider(for: movie) == nil)
    }

    @Test func playerSkipsBrokerWhenOffline() async throws {
        // PlayerScreen hoppar över hemlighet och broker när `localURL` är satt. Modellen har ingen sparad
        // hemlighet, så online-uppspelning går inte att starta; offlinebegäran skapas ändå och bär `localURL`.
        let (m, id, _, root) = try await offlineModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(m.activeProfile?.profile.id)
        let request = try await m.offlineRequest(for: movieDownload(profile: profile, playlist: id, providerID: "101",
                                                                    file: try writeFile(root)))
        #expect(request.localURL != nil)
    }
}
