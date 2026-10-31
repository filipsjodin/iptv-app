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

    func openSubtitlesLogout() throws {
        guard !kidsRestricted else { throw SubtitleAccessError.notAllowed }
        if let service = subtitleService {
            try service.logout()
        } else {
            try subtitleCredentials.clear()
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
