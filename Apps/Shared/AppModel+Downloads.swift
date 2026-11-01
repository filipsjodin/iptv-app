import Core
import Downloads
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Providers

/// Fasta fel för offlineuppspelning. Aldrig sökväg, URL eller servertext.
enum OfflinePlaybackError: Error, Sendable, Equatable {
    /// Raden är inte färdig, saknar fil eller filen finns inte längre på disken.
    case fileMissing
}

/// Var nästa-avsnitt-leverantören befinner sig.
@MainActor
private final class OfflineEpisodeCursor {
    var providerID: String
    init(providerID: String) { self.providerID = providerID }
}

/// Offlineuppspelning av nedladdade titlar. Går aldrig via `playbackRequest` (katalograden kan vara borta), så
/// barnprofilens kontroll görs om här, och ingen hemlighet eller anslutningsplats behövs.
extension AppModel {
    /// `ProgressKey` som online-uppspelningen använder för samma titel, så att positionen delas.
    nonisolated static func offlineProgressKey(for download: StoredDownload) -> ProgressKey {
        ProgressKey(playlistID: download.key.playlistID, kind: download.key.kind,
                    providerID: download.key.providerID,
                    seriesProviderID: download.key.kind == .series ? download.snapshot.seriesProviderID : nil)
    }

    /// Uppspelningsbegäran för en färdig nedladdning.
    ///
    /// - Throws: `PlaybackLookupError.notAllowed` om nedladdningen inte tillhör den aktiva profilen, eller om den
    ///   aktiva profilen är en barnprofil och titeln inte har en känd, godkänd åldersgräns (stängt som standard,
    ///   även om raden finns kvar eller en annan profil laddat ner den). `OfflinePlaybackError.fileMissing` om
    ///   filen inte finns.
    func offlineRequest(for download: StoredDownload) async throws -> PlaybackRequest {
        guard let active = activeProfile, active.profile.id == download.key.profileID,
              download.key.kind != .live else { throw PlaybackLookupError.notAllowed }
        let progressKey = Self.offlineProgressKey(for: download)
        if active.profile.isKids {
            let discovery = discovery
            let allowed = (try? await offMain { Self.allowedForKids(discovery, key: progressKey) }) ?? false
            guard allowed else { throw PlaybackLookupError.notAllowed }
        }
        guard download.state == .completed, let fileURL = download.fileURL,
              await Self.fileExists(fileURL) else { throw OfflinePlaybackError.fileMissing }

        let title: String
        if download.key.kind == .series, let season = download.snapshot.season, let number = download.snapshot.episode {
            let label = "S\(season):E\(number)"
            title = download.snapshot.seriesTitle.map { "\($0) · \(label)" } ?? "\(label) \(download.snapshot.title)"
        } else {
            title = download.snapshot.title
        }
        return PlaybackRequest(key: progressKey, title: title, locator: download.snapshot.locator,
                               container: OfflinePlayback.container(forFileExtension: fileURL.pathExtension),
                               isLive: false,
                               startAt: DetailPresentation.startPosition(progress: userState.progress(for: progressKey),
                                                                         fromStart: false),
                               localURL: fileURL)
    }

    /// Nästa färdiga nedladdade avsnitt i samma serie (säsong, avsnitt), eller `nil`. Avsnitt som inte är
    /// nedladdade hoppas över. Bara för serieavsnitt; filmer ger `nil`. Nästa avsnitt startar från sparad position.
    func offlineNextEpisodeProvider(for request: PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)? {
        guard request.localURL != nil, request.key.kind == .series,
              let seriesID = request.key.seriesProviderID, let profileID = activeProfile?.profile.id else { return nil }
        let playlistID = request.key.playlistID
        let cursor = OfflineEpisodeCursor(providerID: request.key.providerID)
        return { [weak self] in
            guard let self, let store = self.downloadStore,
                  let all = try? await offMain({ try store.list(profileID: profileID, playlistID: playlistID) })
            else { return nil }
            let episodes = all.filter {
                $0.key.kind == .series && $0.state == .completed && $0.snapshot.seriesProviderID == seriesID
                    && $0.fileURL != nil
            }
            let available = episodes.compactMap { d -> OfflineEpisode? in
                guard let season = d.snapshot.season, let number = d.snapshot.episode else { return nil }
                return OfflineEpisode(providerID: d.key.providerID, season: season, number: number)
            }
            // Pröva kandidaterna i ordning tills en har en fil på disken och klarar kontrollen.
            for next in OfflinePlayback.following(cursor.providerID, in: available) {
                guard let download = episodes.first(where: { $0.key.providerID == next.providerID }),
                      var nextRequest = try? await self.offlineRequest(for: download) else { continue }
                nextRequest.startAt = nil
                cursor.providerID = next.providerID
                return nextRequest
            }
            return nil
        }
    }

    nonisolated private static func fileExists(_ url: URL) async -> Bool {
        let path = url.path
        return (try? await offMain { FileManager.default.fileExists(atPath: path) }) ?? false
    }
}

/// Fasta fel för nedladdnings-API:t. Aldrig sökväg, URL eller servertext.
enum DownloadAPIError: Error, Sendable, Equatable {
    /// Barnprofil, ingen aktiv profil, annan spellista än profilens, tvOS eller nedladdningar ej inkopplade.
    case notAllowed
    /// Titeln eller avsnittet finns inte i katalogen.
    case notFound
}

#if !os(tvOS)
/// Bilder som hör till titeln och inte till ett enskilt avsnitt.
private struct SharedArtwork: Sendable {
    var poster: Data?
    var backdrop: Data?
}

/// Var titelns bilder och längd finns.
private struct TitleArt: Sendable {
    var poster: URL?
    var backdrop: URL?
    var runtimeSeconds: Int?
}

/// Nedladdnings-API:t mot gränssnittet. Alla funktioner nekas (kastar `.notAllowed`, eller ger tomt) för
/// barnprofiler och utan aktiv profil; hanteraren anropas då aldrig. Varje nedladdning sparar en ögonblicksbild
/// (katalograden kan försvinna vid nästa import) och hämtar bilder som lokala filer. Bildfel stoppar aldrig
/// nedladdningen.
extension AppModel {
    /// Nedladdningar är möjliga: inte barnläge (inte heller utan profil), iOS/iPadOS och lagret finns.
    var downloadsAvailable: Bool {
        !kidsRestricted && downloadStore != nil && downloadManager != nil
    }

    func downloadMovie(providerID: String, playlistID: UUID) async throws {
        let (manager, profileID) = try downloadContext(playlistID: playlistID)
        let store = store
        let movie = try await Self.downloadRead { try store.movie(playlistID: playlistID, providerID: providerID) }
        guard let movie else { throw DownloadAPIError.notFound }
        let art = await titleArt(playlistID: playlistID, kind: .movie, providerID: providerID,
                                 fallbackPoster: movie.posterURL)
        let snapshot = DownloadSnapshot(title: movie.title, year: movie.year,
                                        container: movie.container ?? Self.container(of: movie.locator),
                                        durationSeconds: art.runtimeSeconds, locator: movie.locator)
        let key = DownloadKey(profileID: profileID, playlistID: playlistID, kind: .movie, providerID: providerID)
        _ = try downloadContext(playlistID: playlistID, expecting: profileID)
        var alreadyThere = manager.items.first { $0.key == key }?.state != nil
        if case .failed? = manager.items.first(where: { $0.key == key })?.state { alreadyThere = false }
        try await manager.enqueue(snapshot, key: key)
        // En redan köad eller nedladdad film får behålla sina bilder.
        guard !alreadyThere else { return }
        let shared = await Self.fetchSharedArtwork(art, http: http)
        await storeArtwork(shared, stillURL: nil, key: key, manager: manager)
    }

    func downloadEpisode(providerID: String, seriesProviderID: String, playlistID: UUID) async throws {
        try await downloadEpisodes(.episode(providerID, seriesID: seriesProviderID),
                                   seriesProviderID: seriesProviderID, playlistID: playlistID)
    }

    /// Alla avsnitt i säsongen som saknas, i spelordning. Avsnitten hämtas vid behov (`get_series_info`).
    func downloadSeason(_ season: Int, seriesProviderID: String, playlistID: UUID) async throws {
        try await downloadEpisodes(.season(season, seriesID: seriesProviderID),
                                   seriesProviderID: seriesProviderID, playlistID: playlistID)
    }

    /// De `count` nästa avsnitten efter `episodeProviderID`, eller efter det senast sedda avsnittet om ankare saknas.
    func downloadNextEpisodes(count: Int, seriesProviderID: String, after episodeProviderID: String?,
                              playlistID: UUID, requiresWifi: Bool = false) async throws {
        try await downloadEpisodes(.nextEpisodes(count: count, after: episodeProviderID, seriesID: seriesProviderID),
                                   seriesProviderID: seriesProviderID, playlistID: playlistID,
                                   requiresWifi: requiresWifi)
    }

    /// Tillstånd för knappar. `nil` när ingen nedladdning finns, och alltid för barnprofiler och andra profilers rader.
    func downloadState(for key: DownloadKey) -> DownloadState? {
        guard downloadsAvailable, let manager = downloadManager, activeProfile?.profile.id == key.profileID
        else { return nil }
        return manager.items.first { $0.key == key }?.state
    }

    /// Lokal bildfil för en nedladdad titel, eller `nil`. Ingen nätverks- eller diskåtkomst utöver filsökvägen.
    func downloadedArtworkURL(for key: DownloadKey, kind: ArtworkKind) -> URL? {
        guard downloadsAvailable, let manager = downloadManager, activeProfile?.profile.id == key.profileID,
              let item = manager.items.first(where: { $0.key == key }) else { return nil }
        switch kind {
        case .poster: return item.artworkURLs.poster
        case .backdrop: return item.artworkURLs.backdrop
        case .still: return item.artworkURLs.still
        case .logo: return nil
        }
    }

    /// Avbryter och tar bort nedladdningen: rad, videofil och bilder. Undertexter rörs aldrig (de hör till
    /// titeln, `SubtitleKey`, inte till nedladdningen). Rader som inte tillhör den aktiva profilen rörs inte.
    func removeDownload(_ key: DownloadKey) async {
        guard downloadsAvailable, let manager = downloadManager, activeProfile?.profile.id == key.profileID
        else { return }
        await manager.cancel(key)
    }

    // MARK: - Internt

    /// Hanteraren och den aktiva profilens id, eller `.notAllowed`. Med `expecting` måste samma profil fortfarande
    /// vara aktiv (kontrolleras igen efter varje väntan).
    private func downloadContext(playlistID: UUID, expecting: UUID? = nil) throws -> (DownloadManager, UUID) {
        guard downloadsAvailable, let manager = downloadManager, let active = activeProfile,
              active.profile.playlistID == playlistID, expecting == nil || active.profile.id == expecting
        else { throw DownloadAPIError.notAllowed }
        return (manager, active.profile.id)
    }

    private func downloadEpisodes(_ request: DownloadPlanner.Request, seriesProviderID: String,
                                  playlistID: UUID, requiresWifi: Bool = false) async throws {
        let (manager, profileID) = try downloadContext(playlistID: playlistID)
        let all = try await episodes(for: seriesProviderID, playlistID: playlistID)
        _ = try downloadContext(playlistID: playlistID, expecting: profileID)

        let existing = Set(manager.items.compactMap { item -> String? in
            guard item.key.profileID == profileID, item.key.playlistID == playlistID, item.key.kind == .series
            else { return nil }
            if case .failed = item.state { return nil }
            return item.key.providerID
        })
        // Bara färdigsedda avsnitt räknas: ett pågående avsnitt ska ingå i nedladdningen.
        var watched = Set<String>()
        for entry in userState.entries(playlistID: playlistID)
        where entry.key.kind == .series && entry.key.seriesProviderID == seriesProviderID && entry.watched {
            watched.insert(entry.key.providerID)
        }
        let ids = DownloadPlanner.plan(request, episodes: all, alreadyDownloaded: existing, watched: watched)
        guard !ids.isEmpty else { return }
        let byID = Dictionary(all.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        let planned = ids.compactMap { byID[$0] }
        guard !planned.isEmpty else { throw DownloadAPIError.notFound }

        let store = store
        let series = try await Self.downloadRead {
            try store.series(playlistID: playlistID, providerID: seriesProviderID)
        }
        let art = await titleArt(playlistID: playlistID, kind: .series, providerID: seriesProviderID,
                                 fallbackPoster: series?.posterURL)
        // Först köas alla rader, sedan hämtas bilderna. Felar något mitt i (t.ex. profilbyte) ligger de redan
        // köade avsnitten kvar; ingen återställning görs.
        var queued: [(DownloadKey, URL?)] = []
        for episode in planned {
            let snapshot = DownloadSnapshot(
                title: episode.title, year: series?.year, season: episode.season, episode: episode.number,
                container: episode.container ?? Self.container(of: episode.locator),
                durationSeconds: episode.durationSeconds, seriesProviderID: seriesProviderID,
                seriesTitle: series?.title, locator: episode.locator)
            let key = DownloadKey(profileID: profileID, playlistID: playlistID, kind: .series,
                                  providerID: episode.providerID)
            _ = try downloadContext(playlistID: playlistID, expecting: profileID)
            try await manager.enqueue(snapshot, key: key, requiresWifi: requiresWifi)
            queued.append((key, episode.stillURL))
        }
        let shared = await Self.fetchSharedArtwork(art, http: http)
        for (key, stillURL) in queued {
            await storeArtwork(shared, stillURL: stillURL, key: key, manager: manager)
        }
    }

    /// Sparar bilderna för en köad nedladdning. Alla fel sväljs: bilder är bara en bonus.
    private func storeArtwork(_ shared: SharedArtwork, stillURL: URL?, key: DownloadKey,
                              manager: DownloadManager) async {
        guard (try? downloadContext(playlistID: key.playlistID, expecting: key.profileID)) != nil else { return }
        let still = await Self.fetchImage(stillURL, http: http)
        guard shared.poster != nil || shared.backdrop != nil || still != nil, let store = downloadStore else { return }
        let poster = shared.poster, backdrop = shared.backdrop
        try? await offMain(priority: .utility) {
            try store.saveArtwork(poster: poster, backdrop: backdrop, still: still, for: key)
        }
        await manager.refreshArtwork(key)
    }

    /// TMDB-bild om metadata finns, annars leverantörens affisch; TMDB-längd när den är känd.
    private func titleArt(playlistID: UUID, kind: ContentKind, providerID: String,
                          fallbackPoster: URL?) async -> TitleArt {
        let store = metadataStore
        let found = try? await offMain(priority: .utility) { () throws -> TitleArt in
            var art = TitleArt(poster: nil, backdrop: nil, runtimeSeconds: nil)
            guard let id = try store.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID),
                  let meta = try store.metadata(kind: kind, tmdbID: id) else { return art }
            if let path = meta.posterPath, !path.isEmpty {
                art.poster = TMDBImage.url(path: path, size: ArtworkKind.poster.tmdbSize)
            }
            if let path = meta.backdropPath, !path.isEmpty {
                art.backdrop = TMDBImage.url(path: path, size: ArtworkKind.backdrop.tmdbSize)
            }
            if kind == .movie, let minutes = meta.runtimeMinutes, minutes > 0 { art.runtimeSeconds = minutes * 60 }
            return art
        }
        var art = found ?? TitleArt(poster: nil, backdrop: nil, runtimeSeconds: nil)
        if art.poster == nil { art.poster = fallbackPoster }
        return art
    }

    nonisolated private static func fetchSharedArtwork(_ art: TitleArt, http: HTTPClient) async -> SharedArtwork {
        async let poster = fetchImage(art.poster, http: http)
        async let backdrop = fetchImage(art.backdrop, http: http)
        return await SharedArtwork(poster: poster, backdrop: backdrop)
    }

    /// Hämtar en bild (högst 10 MB). `nil` vid fel, tom eller för stor bild, eller annat än http/https.
    nonisolated private static func fetchImage(_ url: URL?, http: HTTPClient) async -> Data? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let result = try? await http.get(url), (200..<300).contains(result.1),
              !result.0.isEmpty, result.0.count <= 10_000_000 else { return nil }
        return result.0
    }

    /// Databasläsning utanför huvudaktören; fel blir `ImportError.storageFailed`.
    nonisolated private static func downloadRead<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await offMain(work)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportError.storageFailed
        }
    }
}
#else
extension AppModel {
    var downloadsAvailable: Bool { false }
    func downloadMovie(providerID: String, playlistID: UUID) async throws { throw DownloadAPIError.notAllowed }
    func downloadEpisode(providerID: String, seriesProviderID: String, playlistID: UUID) async throws {
        throw DownloadAPIError.notAllowed
    }
    func downloadSeason(_ season: Int, seriesProviderID: String, playlistID: UUID) async throws {
        throw DownloadAPIError.notAllowed
    }
    func downloadNextEpisodes(count: Int, seriesProviderID: String, after episodeProviderID: String?,
                              playlistID: UUID, requiresWifi: Bool = false) async throws {
        throw DownloadAPIError.notAllowed
    }
    func downloadState(for key: DownloadKey) -> DownloadState? { nil }
    func downloadedArtworkURL(for key: DownloadKey, kind: ArtworkKind) -> URL? { nil }
    func removeDownload(_ key: DownloadKey) async {}
}
#endif
