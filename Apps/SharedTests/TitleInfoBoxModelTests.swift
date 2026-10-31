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

@MainActor
private func infoModel() async throws -> (AppModel, UUID) {
    let db = try AppDatabase.inMemory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("title-info-tests-\(UUID().uuidString)")
    let m = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                     openSubtitlesKey: "fake-os-key-123456", subtitleStore: SubtitleStore(db: db, directory: dir),
                     subtitleCredentials: InMemoryOpenSubtitlesCredentialStore())
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    return (m, try #require(m.playlists.first?.id))
}

private func tech(_ audio: [String] = ["sv", "en"], subs: [String] = ["sv"], video: String? = "2160p · Dolby Vision",
                  engine: String? = "Apple") -> TitleTechInfo {
    TitleTechInfo(audioLanguages: audio, subtitleLanguages: subs, videoSummary: video, engine: engine,
                  recordedAt: Date(timeIntervalSince1970: 1))
}

@MainActor
private func key(_ m: AppModel, _ playlistID: UUID, kind: ContentKind = .movie, providerID: String = "101")
    throws -> SubtitleKey {
    SubtitleKey(profileID: try #require(m.activeProfile).profile.id, playlistID: playlistID, kind: kind,
                providerID: providerID)
}

private let upper: @Sendable (String) -> String = { $0.uppercased() }

private func track(_ id: String, _ kind: TrackKind, _ language: String?, title: String = "") -> MediaTrack {
    MediaTrack(id: id, kind: kind, languageCode: language, title: title, codec: nil, channelCount: nil,
               isAtmos: false, isDefault: false, isForced: false)
}

@MainActor
struct TitleInfoBoxModelTests {
    @Test func infoModelFromRecordedTechInfo() async throws {
        // Ren formatering.
        let model = TitleInfoModel.make(tech: tech(["sv", "en", "sv"]), downloaded: [], languageName: upper)
        #expect(model.audio == ["SV", "EN"])
        #expect(model.subtitles == ["SV"])
        #expect(model.video == "2160p · Dolby Vision")
        #expect(model.engine == "Apple")
        #expect(!model.isEmpty && model.hasPlaybackInfo)

        // Skriven och inläst via appen.
        let (m, id) = try await infoModel()
        m.enter(playlistID: id)
        try #require(m.activeProfile != nil)
        await m.writeTechInfo(tech(), key: try key(m, id))
        let loaded = try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id))
        #expect(loaded.video == "2160p · Dolby Vision" && loaded.engine == "Apple")
        #expect(loaded.audio.count == 2 && loaded.subtitles.count == 1)
    }

    @Test func emptyBeforeFirstPlayback() async throws {
        let (m, id) = try await infoModel()
        m.enter(playlistID: id)
        let loaded = try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id))
        #expect(loaded.isEmpty && !loaded.hasPlaybackInfo)
        #expect(loaded.audio.isEmpty && loaded.subtitles.isEmpty && loaded.video == nil && loaded.engine == nil)
        // Tom teknisk info bygger en tom modell.
        #expect(TitleInfoModel.make(tech: nil, downloaded: []).isEmpty)
    }

    @Test func downloadedListedAndRemovable() async throws {
        let (m, id) = try await infoModel()
        m.enter(playlistID: id)
        let k = try key(m, id)
        let result = OpenSubtitlesResult(id: 11, language: "sv", release: "Rel.1080p", fileName: "a.srt", rating: 1,
                                         downloadCount: 1, hearingImpaired: false, aiTranslated: false)
        let data = Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8)
        _ = try #require(m.subtitleStore).save(data, result: result, for: k)

        let context = try #require(await m.titleInfoContext(kind: .movie, providerID: "101", playlistID: id))
        #expect(context.info.downloaded.map(\.id) == [11])
        #expect(!context.info.isEmpty && !context.info.hasPlaybackInfo)
        #expect(context.info.downloadedRows(languageName: upper).map(\.text) == ["SV · Rel.1080p"])

        let request = try #require(context.request)
        let removed = await m.removeStoredSubtitle(context.info.downloaded[0], for: request, playlistID: id)
        #expect(removed)
        let after = try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id))
        #expect(after.downloaded.isEmpty)
    }

    @Test func kidsProfileGetsNilInfo() async throws {
        let (m, id) = try await infoModel()
        let adult = try m.addProfile(playlistID: id, name: "Vuxen", avatar: "person.fill")
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: adult, pin: nil)
        let adultKey = try key(m, id)
        await m.writeTechInfo(tech(), key: adultKey)

        try await m.select(profile: kid, pin: nil)
        try #require(m.kidsRestricted)
        #expect(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id) == nil)
        #expect(await m.titleInfoContext(kind: .series, providerID: "5", playlistID: id) == nil)

        // Ingen skrivning i barnläge, inte ens med en egen nyckel.
        let kidKey = SubtitleKey(profileID: kid.id, playlistID: id, kind: .movie, providerID: "101")
        await m.writeTechInfo(tech(), key: kidKey)
        #expect(try #require(m.subtitleStore).techInfo(for: kidKey) == nil)
    }

    @Test func recordTechInfoWritesOffMainAndPerProfile() async throws {
        // Spåren blir teknisk info: inbyggda textspår räknas, externa inte, dubbletter slås ihop.
        let info = try #require(AppModel.techInfo(
            audio: [track("a1", .audio, "sv"), track("a2", .audio, "en"), track("a3", .audio, "sv")],
            subtitles: [track("s1", .subtitle, "sv"), track("ext:7", .subtitle, "en"),
                        track("s2", .subtitle, nil, title: "Forced")],
            video: VideoInfo(width: 3840, height: 2160, dynamicRange: .dolbyVision, videoCodec: nil,
                             audioDescription: nil, bitrate: nil, frameRate: nil),
            engine: .vlc, recordedAt: Date(timeIntervalSince1970: 5)))
        #expect(info.audioLanguages == ["sv", "en"])
        #expect(info.subtitleLanguages == ["sv", "Forced"])
        #expect(info.videoSummary == "2160p · Dolby Vision" && info.engine == "VLC")
        // Inget känt: inget sparas.
        #expect(AppModel.techInfo(audio: [], subtitles: [track("ext:7", .subtitle, "en")], video: .unknown,
                                  engine: .avPlayer, recordedAt: Date()) == nil)

        // Per profil och titel: en annan profil ser inget. Skrivningen går via `offMain` (databasen rörs inte på
        // huvudtråden); här verifieras resultatet, inte tråden.
        let (m, id) = try await infoModel()
        let a = try m.addProfile(playlistID: id, name: "A", avatar: "person.fill")
        let b = try m.addProfile(playlistID: id, name: "B", avatar: "person.fill")
        try await m.select(profile: a, pin: nil)
        await m.writeTechInfo(info, key: try key(m, id))
        #expect(try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id)).engine == "VLC")
        #expect(try #require(await m.titleInfo(kind: .movie, providerID: "103", playlistID: id)).isEmpty)

        try await m.select(profile: b, pin: nil)
        #expect(try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id)).isEmpty)
        try await m.select(profile: a, pin: nil)
        #expect(try #require(await m.titleInfo(kind: .movie, providerID: "101", playlistID: id)).engine == "VLC")
    }

    @Test func seriesUsesLastPlayedEpisode() async throws {
        let (m, id) = try await infoModel()
        m.enter(playlistID: id)
        _ = try await m.episodes(for: "5", playlistID: id)

        // Inget spelat: tom ruta, ingen sökning.
        let none = try #require(await m.titleInfoContext(kind: .series, providerID: "5", playlistID: id))
        #expect(none.info.isEmpty && none.request == nil)

        func key(_ episode: String) throws -> SubtitleKey { try TitleInfoBoxModelTests.episodeKey(m, id, episode) }
        await m.writeTechInfo(tech(["sv"], video: "720p"), key: try key("501"))
        await m.writeTechInfo(tech(["en"], video: "1080p"), key: try key("502"))
        m.userState.save(WatchProgress(
            key: ProgressKey(playlistID: id, kind: .series, providerID: "501", seriesProviderID: "5"),
            position: 10, duration: 100, watched: true, updatedAt: Date(timeIntervalSince1970: 10)))
        m.userState.save(WatchProgress(
            key: ProgressKey(playlistID: id, kind: .series, providerID: "502", seriesProviderID: "5"),
            position: 10, duration: 100, watched: false, updatedAt: Date(timeIntervalSince1970: 20)))

        let context = try #require(await m.titleInfoContext(kind: .series, providerID: "5", playlistID: id))
        #expect(context.info.video == "1080p")
        #expect(context.request?.key.providerID == "502")
        #expect(context.request?.key.seriesProviderID == "5")
        #expect(context.request?.key.kind == .series)
    }

    private static func episodeKey(_ m: AppModel, _ playlistID: UUID, _ episode: String) throws -> SubtitleKey {
        SubtitleKey(profileID: try #require(m.activeProfile).profile.id, playlistID: playlistID, kind: .series,
                    providerID: episode)
    }
}
