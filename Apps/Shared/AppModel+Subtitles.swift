import Core
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Subtitles

/// Fel från undertextsfunktionerna som inte kommer från OpenSubtitles. Bär aldrig uppgifter eller nyckel.
enum SubtitleAccessError: Error, Equatable {
    /// Barnprofil eller ingen aktiv profil: inga sökningar, nedladdningar, inloggningar eller andra externa anrop.
    case notAllowed
    /// Ingen API-nyckel (eller inget undertextslager): funktionen är avstängd.
    case featureDisabled
    /// Titeln saknar både metadata och titel/avsnittsnummer att söka på.
    case noQuery
}

/// OpenSubtitles: sökning, nedladdning, lagrade undertexter, tidsförskjutning och konto. Allt är stängt i barnläge
/// (`kidsRestricted`, vilket också gäller utan aktiv profil): då görs inga anrop alls.
extension AppModel {
    /// Nyckel finns och profilen är inte en barnprofil.
    var subtitlesAvailable: Bool { !kidsRestricted && subtitleService != nil }

    /// Inloggad hos OpenSubtitles (uppgifter sparade). Alltid falskt i barnläge.
    var openSubtitlesLoggedIn: Bool { !kidsRestricted && openSubtitlesCredentialsSaved }

    /// Nyckeln för titelns undertexter. `nil` för live, i barnläge och utan lager.
    func subtitleKey(for request: PlaybackRequest, playlistID: UUID) -> SubtitleKey? {
        guard !kidsRestricted, subtitleStore != nil, let session = activeProfile,
              !request.isLive, request.key.kind != .live else { return nil }
        return SubtitleKey(profileID: session.profile.id, playlistID: playlistID, kind: request.key.kind,
                           providerID: request.key.providerID)
    }

    // MARK: - Sökning och nedladdning

    func searchSubtitles(for request: PlaybackRequest, playlistID: UUID,
                         languages: [String]) async throws -> [OpenSubtitlesResult] {
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        guard let service = subtitleService, subtitleKey(for: request, playlistID: playlistID) != nil else {
            throw SubtitleAccessError.featureDisabled
        }
        guard let query = await subtitleQuery(for: request, playlistID: playlistID, languages: languages) else {
            throw SubtitleAccessError.noQuery
        }
        // Profilen kan ha bytts under metadatauppslaget.
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        return try await service.search(query, preferredLanguages: languages)
    }

    func downloadSubtitle(_ result: OpenSubtitlesResult, for request: PlaybackRequest,
                          playlistID: UUID) async throws -> (StoredSubtitle, OpenSubtitlesQuota) {
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        guard let service = subtitleService, let key = subtitleKey(for: request, playlistID: playlistID) else {
            throw SubtitleAccessError.featureDisabled
        }
        return try await service.download(result, for: key)
    }

    // MARK: - Lagrade undertexter

    /// Lagrade undertexter och tidsförskjutning för titeln. Tomt (och 0) i barnläge eller vid fel. Läser
    /// databasen utanför huvudtråden.
    func storedSubtitles(for request: PlaybackRequest,
                         playlistID: UUID) async -> (subs: [StoredSubtitle], offset: Double) {
        guard let key = subtitleKey(for: request, playlistID: playlistID), let store = subtitleStore else {
            return ([], 0)
        }
        let loaded = try? await offMain { () throws -> ([StoredSubtitle], Double) in
            (try store.list(for: key), try store.offset(for: key))
        }
        guard !kidsRestricted, let loaded else { return ([], 0) }
        return (loaded.0, loaded.1)
    }

    /// Sparar tidsförskjutningen (sekunder, begränsad till ±`SubtitleTrack.maxOffset`). Ingenting i barnläge.
    func setSubtitleOffset(_ seconds: Double, for request: PlaybackRequest, playlistID: UUID) async {
        guard let key = subtitleKey(for: request, playlistID: playlistID), let store = subtitleStore,
              seconds.isFinite else { return }
        let clamped = min(max(seconds, -SubtitleTrack.maxOffset), SubtitleTrack.maxOffset)
        _ = try? await offMain(honorsCancellation: false) { try store.setOffset(clamped, for: key) }
    }

    // MARK: - Konto

    /// Loggar in. Uppgifterna sparas i Keychain först när inloggningen lyckats; vid fel sparas ingenting och
    /// `openSubtitlesLoggedIn` är oförändrat. Lösenordet lämnar aldrig det här anropet.
    func openSubtitlesLogin(username: String, password: String) async throws -> OpenSubtitlesQuota {
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        guard let service = subtitleService else { throw SubtitleAccessError.featureDisabled }
        let quota = try await service.login(username: username, password: password)
        openSubtitlesCredentialsSaved = true
        return quota
    }

    func openSubtitlesLogout() async throws {
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        let service = subtitleService, credentials = subtitleCredentials
        // Keychain-radering utanför huvudtråden; får inte avbrytas halvvägs.
        try await offMain(honorsCancellation: false) {
            if let service {
                try service.logout()
            } else {
                try credentials.clear()
            }
        }
        openSubtitlesCredentialsSaved = false
    }

    /// Återstående dagskvot, eller `nil` (barnläge, ingen nyckel, inte inloggad eller fel).
    func openSubtitlesQuota() async -> OpenSubtitlesQuota? {
        guard !kidsRestricted, let service = subtitleService else { return nil }
        return try? await service.quota()
    }

    /// Läser om (utanför huvudtråden) om uppgifter finns sparade. Ingenting i barnläge.
    func refreshOpenSubtitlesStatus() async {
        guard !kidsRestricted else { return }
        let credentials = subtitleCredentials
        let saved = (try? await offMain { try credentials.load() != nil }) ?? false
        guard !kidsRestricted else { return }
        openSubtitlesCredentialsSaved = saved
    }

    // MARK: - Fråga

    /// Bygger sökfrågan ur titelns TMDB-metadata (film, eller serien för ett avsnitt) och avsnittets säsong och
    /// nummer. Saknas metadata används titel och år ur biblioteket. `nil` när inget går att söka på.
    func subtitleQuery(for request: PlaybackRequest, playlistID: UUID,
                       languages: [String]) async -> OpenSubtitlesQuery? {
        guard !kidsRestricted else { return nil }
        let store = store
        if let seriesID = request.key.seriesProviderID {
            let episodeID = request.key.providerID
            let episodes = try? await offMain { try store.episodes(playlistID: playlistID, seriesProviderID: seriesID) }
            guard let episode = episodes?.first(where: { $0.providerID == episodeID }) else { return nil }
            let meta = await metadata.metadata(playlistID: playlistID, kind: .series, providerID: seriesID)
            var title: String?
            var year: Int?
            if meta == nil {
                let series = try? await offMain { try store.series(playlistID: playlistID, providerID: seriesID) }
                title = series?.title
                year = series?.year
            }
            return Self.subtitleQuery(metadata: meta, title: title, year: year, season: episode.season,
                                      episode: episode.number, languages: languages)
        }
        guard request.key.kind == .movie else { return nil }
        let movieID = request.key.providerID
        let meta = await metadata.metadata(playlistID: playlistID, kind: .movie, providerID: movieID)
        var title: String? = request.title
        var year: Int?
        if meta == nil {
            let movie = try? await offMain { try store.movie(playlistID: playlistID, providerID: movieID) }
            title = movie?.title ?? request.title
            year = movie?.year
        }
        return Self.subtitleQuery(metadata: meta, title: title, year: year, season: nil, episode: nil,
                                  languages: languages)
    }

    /// Rena regler för frågan: TMDB-id (och IMDb-id) när metadata finns, annars titel och år. Avsnitt bär alltid
    /// säsong och avsnittsnummer. `nil` utan både id och titel.
    nonisolated static func subtitleQuery(metadata: TitleMetadata?, title: String?, year: Int?, season: Int?,
                                          episode: Int?, languages: [String]) -> OpenSubtitlesQuery? {
        if let metadata {
            let imdb = metadata.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenSubtitlesQuery(tmdbID: metadata.tmdbID, imdbID: (imdb?.isEmpty ?? true) ? nil : imdb,
                                      season: season, episode: episode, languages: languages)
        }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return OpenSubtitlesQuery(season: season, episode: episode, title: title, year: year, languages: languages)
    }
}

// MARK: - Info-ruta på detaljsidan

/// Det detaljsidans info-ruta behöver: de färdigformaterade uppgifterna och begäran sökningen görs för (filmen, eller
/// serien senast spelade avsnitt). `request` är `nil` när inget går att söka för (serie utan spelat avsnitt).
struct TitleInfoContext {
    var info: TitleInfoModel
    var request: PlaybackRequest?
}

extension AppModel {
    /// Det en läsning av info-rutan ger (läses i ett svep utanför huvudtråden).
    private struct LoadedTitleInfo: Sendable {
        var request: PlaybackRequest?
        var key: SubtitleKey?
        var tech: TitleTechInfo?
        var downloaded: [StoredSubtitle]
    }

    /// Ljud, textspår, video och spelare som sparats för titeln, samt nedladdade undertexter. `nil` i barnläge, utan
    /// aktiv profil och utan undertextslager (ingen ruta alls). För serier gäller uppgifterna senast spelade avsnitt.
    /// Läser databasen utanför huvudtråden; anropas en gång när detaljsidan visas.
    func titleInfo(kind: ContentKind, providerID: String, playlistID: UUID) async -> TitleInfoModel? {
        await titleInfoContext(kind: kind, providerID: providerID, playlistID: playlistID)?.info
    }

    func titleInfoContext(kind: ContentKind, providerID: String, playlistID: UUID) async -> TitleInfoContext? {
        guard !kidsRestricted, let profile = activeProfile,
              let subtitleStore = self.subtitleStore, kind == .movie || kind == .series
        else { return nil }
        let profileID = profile.profile.id
        let library = store, state = userState
        let loaded = try? await offMain { () throws -> LoadedTitleInfo in
            var request: PlaybackRequest?
            if kind == .movie {
                if let movie = try library.movie(playlistID: playlistID, providerID: providerID) {
                    request = PlaybackRequest(
                        key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: providerID),
                        title: movie.title, locator: movie.locator, container: movie.container, isLive: false)
                }
            } else if let last = state.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: providerID),
                      let episode = try library.episodes(playlistID: playlistID, seriesProviderID: providerID)
                          .first(where: { $0.providerID == last.key.providerID }) {
                request = PlaybackRequest(
                    key: ProgressKey(playlistID: playlistID, kind: .series, providerID: episode.providerID,
                                     seriesProviderID: providerID),
                    title: "S\(episode.season):E\(episode.number) \(episode.title)", locator: episode.locator,
                    container: episode.container, isLive: false)
            }
            guard let request else { return LoadedTitleInfo(request: nil, key: nil, tech: nil, downloaded: []) }
            let key = SubtitleKey(profileID: profileID, playlistID: playlistID, kind: request.key.kind,
                                  providerID: request.key.providerID)
            return LoadedTitleInfo(request: request, key: key, tech: try subtitleStore.techInfo(for: key),
                                   downloaded: try subtitleStore.list(for: key))
        }
        // Profilen kan ha bytts (till en barnprofil) under läsningen.
        guard !kidsRestricted, activeProfile?.profile.id == profileID else { return nil }
        let found = loaded ?? LoadedTitleInfo(request: nil, key: nil, tech: nil, downloaded: [])
        return TitleInfoContext(info: TitleInfoModel.make(tech: found.tech, downloaded: found.downloaded),
                                request: found.request)
    }

    /// Tar bort en nedladdad undertext (fil och rad). Ingenting i barnläge. Sant om borttagningen lyckades.
    func removeStoredSubtitle(_ subtitle: StoredSubtitle, for request: PlaybackRequest, playlistID: UUID) async -> Bool {
        guard let key = subtitleKey(for: request, playlistID: playlistID), let store = subtitleStore else { return false }
        let id = subtitle.id
        let removed: Bool? = try? await offMain(honorsCancellation: false) {
            try store.remove(fileID: id, for: key)
            return true
        }
        return removed == true
    }

    /// Tekniken som spelaren observerat. `nil` när inget är känt (då sparas ingenting). Bara inbyggda textspår
    /// räknas; nedladdade listas för sig.
    nonisolated static func techInfo(audio: [MediaTrack], subtitles: [MediaTrack], video: VideoInfo?,
                                     engine: EngineKind?, recordedAt: Date) -> TitleTechInfo? {
        func languages(_ tracks: [MediaTrack]) -> [String] {
            var seen = Set<String>()
            return tracks.compactMap { track -> String? in
                let value = (track.languageCode?.isEmpty == false ? track.languageCode : nil) ?? track.title
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || !seen.insert(trimmed).inserted ? nil : trimmed
            }
        }
        let audioLanguages = languages(audio)
        let subtitleLanguages = languages(subtitles.filter { !$0.isExternal })
        let summary = video?.summary
        let videoSummary = (summary?.isEmpty ?? true) ? nil : summary
        guard !audioLanguages.isEmpty || !subtitleLanguages.isEmpty || videoSummary != nil else { return nil }
        return TitleTechInfo(audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
                             videoSummary: videoSummary, engine: engine?.displayName, recordedAt: recordedAt)
    }

    /// Anropas när motorn laddat: sparar ljud, textspår, video och spelare för titelns nyckel (per profil). Skriver
    /// aldrig på huvudtråden och ingenting i barnläge eller för live.
    func recordTechInfo(from session: PlaybackSession, request: PlaybackRequest, playlistID: UUID) {
        guard let key = subtitleKey(for: request, playlistID: playlistID), let engine = session.engine,
              let info = Self.techInfo(audio: engine.audioTracks, subtitles: engine.subtitleTracks,
                                       video: engine.videoInfo, engine: engine.kind, recordedAt: Date())
        else { return }
        Task { await writeTechInfo(info, key: key) }
    }

    /// Skrivningen, utanför huvudtråden. Ingenting i barnläge eller om profilen bytts sedan nyckeln togs.
    func writeTechInfo(_ info: TitleTechInfo, key: SubtitleKey) async {
        guard !kidsRestricted, activeProfile?.profile.id == key.profileID, let store = subtitleStore else { return }
        _ = try? await offMain(honorsCancellation: false) { try store.recordTechInfo(info, for: key) }
    }
}
