import Core
import Foundation
import Library
import Observation
import Playback
import PlaybackCore
import Providers
import Secrets

@MainActor @Observable
final class AppModel {
    var playlists: [Playlist] = []
    var counts: [UUID: [ContentKind: Int]] = [:]
    var importState: [UUID: ImportPhase] = [:]
    /// Lokaliserat, fast meddelande. Innehåller aldrig server, URL, användarnamn eller underliggande fel.
    var lastError: String?
    /// Kontoinformation per spellista (utgångsdatum, max anslutningar) när leverantören uppger den.
    var accountInfo: [UUID: PlaylistAccountInfo] = [:]

    let store: LibraryStore
    /// Tittarpositioner. En enda instans per nyckel i appen (flera instanser skulle skriva över varandra).
    let userState: any UserStateStore
    /// Uppspelningsinställningar; sparas vid varje ändring.
    var settings: PlaybackSettings {
        didSet { settings.save(to: defaults) }
    }
    private let credentials: CredentialStore
    private let http: HTTPClient
    @ObservationIgnored private let metadata: PlaylistMetadataStore
    @ObservationIgnored private let defaults: UserDefaults
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    /// Pågående avsnittshämtningar; samtidiga anrop för samma serie delar en hämtning.
    @ObservationIgnored private var episodeTasks: [EpisodeTaskKey: Task<[Episode], Error>] = [:]
    /// Spellistor som håller på att läggas till; deras Keychain-poster får inte städas bort.
    @ObservationIgnored private var pendingAdds: Set<UUID> = []

    private struct EpisodeTaskKey: Hashable {
        let playlistID: UUID
        let seriesProviderID: String
    }

    /// - Parameter userState: tittarpositioner. Utelämnas den skapas den enda `UserDefaultsUserStateStore`-instansen
    ///   för `defaults` här; tester skickar in `InMemoryUserStateStore`.
    init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient, defaults: UserDefaults = .standard,
         userState: (any UserStateStore)? = nil) {
        self.store = store
        self.credentials = credentials
        self.http = http
        self.metadata = PlaylistMetadataStore(defaults: defaults)
        self.defaults = defaults
        self.userState = userState ?? UserDefaultsUserStateStore(defaults: defaults)
        self.settings = PlaybackSettings.load(from: defaults)
    }

    /// Produktionsuppsättning: databas på disk, Keychain och `URLSessionHTTPClient()` med paketets
    /// standardvärden (30 s per förfrågan, 600 s per resurs – räcker för stora kataloger).
    static func live() -> AppModel {
        let http = URLSessionHTTPClient()
        let credentials = KeychainCredentialStore()
        do {
            return AppModel(store: LibraryStore(db: try LibraryLocation.open()), credentials: credentials, http: http)
        } catch {
            // Sista utväg: en tillfällig databas så att appen ändå startar. Spellistorna återställs från
            // metadata i `load()`.
            // swiftlint:disable:next force_try
            let model = AppModel(store: LibraryStore(db: try! AppDatabase.inMemory()), credentials: credentials,
                                 http: http)
            model.lastError = String(localized: "The library could not be opened on this device.")
            return model
        }
    }

    func isImporting(_ id: UUID) -> Bool { importTasks[id] != nil }

    // MARK: - Uppspelning

    /// Spellistans hemlighet för att lösa upp ström-URL:er. Lämnar aldrig spelarvyn/sessionen.
    func playbackSecret(for playlistID: UUID) async throws -> PlaylistSecret {
        let credentials = credentials
        guard let secret = try await offMain({ try credentials.load(for: playlistID) }) else {
            throw CoreError.missingSecret
        }
        return secret
    }

    /// Avsnitten i en serie. Finns de i databasen används de. Annars hämtas de för Xtream-spellistor via
    /// `get_series_info` och sparas; en M3U-spellista utan avsnitt ger en tom lista. Samtidiga anrop för samma
    /// serie delar en hämtning. Fel är `ProviderError`, `CoreError` eller `ImportError` (aldrig med URL).
    func episodes(for seriesProviderID: String, playlistID: UUID) async throws -> [Episode] {
        let key = EpisodeTaskKey(playlistID: playlistID, seriesProviderID: seriesProviderID)
        if let running = episodeTasks[key] { return try await running.value }
        let store = store, credentials = credentials, http = http
        let task = Task.detached(priority: .userInitiated) {
            try await Self.loadEpisodes(seriesProviderID: seriesProviderID, playlistID: playlistID, store: store,
                                        credentials: credentials, http: http)
        }
        episodeTasks[key] = task
        defer { episodeTasks[key] = nil }
        return try await task.value
    }

    nonisolated private static func loadEpisodes(seriesProviderID: String, playlistID: UUID, store: LibraryStore,
                                                 credentials: CredentialStore,
                                                 http: HTTPClient) async throws -> [Episode] {
        let stored: [Episode], kind: PlaylistSourceKind?
        do {
            stored = try store.episodes(playlistID: playlistID, seriesProviderID: seriesProviderID)
            kind = try store.playlists().first { $0.id == playlistID }?.kind
        } catch {
            throw ImportError.storageFailed
        }
        guard stored.isEmpty else { return stored }
        guard let kind else { throw ImportError.unknownPlaylist }
        guard kind == .xtream else { return [] }
        let loaded: PlaylistSecret?
        do { loaded = try credentials.load(for: playlistID) } catch { throw ImportError.secretUnreadable }
        guard let secret = loaded else { throw CoreError.missingSecret }
        guard case let .xtream(server, username, password) = secret else { throw CoreError.secretKindMismatch }
        let fetched: [Episode]
        do {
            fetched = try await XtreamClient(server: server, username: username, password: password, http: http)
                .episodes(seriesID: seriesProviderID)
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.unreachable
        }
        do {
            try store.upsertEpisodes(fetched, seriesProviderID: seriesProviderID, playlistID: playlistID, now: Date())
            return try store.episodes(playlistID: playlistID, seriesProviderID: seriesProviderID)
        } catch {
            throw ImportError.storageFailed
        }
    }

    /// Uppspelningsbegäran för en film, ett avsnitt (`seriesProviderID` krävs) eller en kanal. `startAt` är
    /// sparad position enligt `ProgressPolicy.resumePosition` (nil = från början; alltid nil för live).
    func playbackRequest(kind: ContentKind, providerID: String, seriesProviderID: String?,
                         playlistID: UUID) async throws -> PlaybackRequest {
        let store = store
        var request: PlaybackRequest
        switch kind {
        case .movie:
            guard let movie = try await Self.read({ try store.movie(playlistID: playlistID, providerID: providerID) })
            else { throw PlaybackLookupError.notFound }
            request = PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: providerID),
                                      title: movie.title, locator: movie.locator, container: movie.container,
                                      isLive: false)
        case .series:
            guard let seriesProviderID else { throw PlaybackLookupError.notFound }
            let all = try await episodes(for: seriesProviderID, playlistID: playlistID)
            guard let episode = all.first(where: { $0.providerID == providerID }) else {
                throw PlaybackLookupError.notFound
            }
            let series = try await Self.read {
                try store.series(playlistID: playlistID, providerID: seriesProviderID)
            }
            request = Self.episodeRequest(episode, seriesTitle: series?.title, playlistID: playlistID)
        case .live:
            guard let locator = try await Self.read({
                try store.locator(playlistID: playlistID, kind: .live, providerID: providerID)
            }) else { throw PlaybackLookupError.notFound }
            request = PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .live, providerID: providerID),
                                      title: providerID, locator: locator, container: Self.container(of: locator),
                                      isLive: true)
        }
        if kind != .live { request.startAt = ProgressPolicy.resumePosition(userState.progress(for: request.key)) }
        return request
    }

    /// Live: bästa varianten i gruppen för skärmen, utan startposition.
    func liveRequest(group: ChannelGroup, playlistID: UUID, displaySupportsHDR: Bool) -> PlaybackRequest {
        let stream = group.preferred(displaySupportsHDR: displaySupportsHDR)
        return PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .live, providerID: stream.providerID),
                               title: group.displayName, locator: stream.locator,
                               container: Self.container(of: stream.locator), isLive: true)
    }

    /// Nästa-avsnitt-leverantör till `PlayerScreen`. Bara för avsnitt; filmer och live får nil (en leverantör
    /// gör att spelaren går vidare när titeln tar slut). Varje anrop går ett avsnitt framåt; nästa avsnitt
    /// startar från sparad position om den finns, annars från början.
    func nextEpisodeProvider(for request: PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)? {
        guard request.key.kind == .series, let seriesID = request.key.seriesProviderID else { return nil }
        let playlistID = request.key.playlistID
        let cursor = EpisodeCursor(providerID: request.key.providerID)
        return { [weak self] in
            guard let self,
                  let all = try? await self.episodes(for: seriesID, playlistID: playlistID),
                  let current = all.first(where: { $0.providerID == cursor.providerID }),
                  let next = NextEpisode.after(current, in: all),
                  var nextRequest = try? await self.playbackRequest(kind: .series, providerID: next.providerID,
                                                                    seriesProviderID: seriesID,
                                                                    playlistID: playlistID)
            else { return nil }
            nextRequest.startAt = nil
            cursor.providerID = next.providerID
            return nextRequest
        }
    }

    /// "Fortsätt titta" för en spellista, nyast först. Poster vars titel eller avsnitt inte längre finns hoppas
    /// över. Läser bara databasen (hämtar inga avsnitt).
    func continueWatching(playlistID: UUID) async -> [ContinueWatchingItem] {
        let entries = userState.continueWatching(playlistID: playlistID, limit: 20)
        guard !entries.isEmpty else { return [] }
        let store = store
        let items = try? await offMain { () throws -> [ContinueWatchingItem] in
            var seriesCache: [String: (series: Series?, episodes: [Episode])] = [:]
            var items: [ContinueWatchingItem] = []
            for progress in entries {
                let key = progress.key
                let fraction = progress.duration.map { min(1, max(0, progress.position / $0)) } ?? 0
                let resume = ProgressPolicy.resumePosition(progress)
                if let seriesID = key.seriesProviderID {
                    if seriesCache[seriesID] == nil {
                        seriesCache[seriesID] = (try store.series(playlistID: playlistID, providerID: seriesID),
                                                 try store.episodes(playlistID: playlistID, seriesProviderID: seriesID))
                    }
                    guard let cached = seriesCache[seriesID], let series = cached.series,
                          let episode = cached.episodes.first(where: { $0.providerID == key.providerID })
                    else { continue }
                    var request = Self.episodeRequest(episode, seriesTitle: series.title, playlistID: playlistID)
                    request.startAt = resume
                    items.append(ContinueWatchingItem(id: "series/\(seriesID)/\(key.providerID)", title: series.title,
                                                      subtitle: Self.episodeLabel(episode), progressFraction: fraction,
                                                      request: request, posterURL: series.posterURL))
                } else if key.kind == .movie {
                    guard let movie = try store.movie(playlistID: playlistID, providerID: key.providerID) else {
                        continue
                    }
                    let request = PlaybackRequest(key: key, title: movie.title, locator: movie.locator,
                                                  container: movie.container, isLive: false, startAt: resume)
                    items.append(ContinueWatchingItem(id: "movie/\(key.providerID)", title: movie.title, subtitle: nil,
                                                      progressFraction: fraction, request: request,
                                                      posterURL: movie.posterURL))
                }
            }
            return items
        }
        return items ?? []
    }

    /// Vad serievyns huvudknapp spelar: senast sedda avsnittet om det inte är sett klart, annars nästa avsnitt.
    /// Saknas båda blir det första avsnittet ("Spela S1:E1").
    nonisolated static func seriesPlayTarget(episodes: [Episode], last: WatchProgress?) -> SeriesPlayTarget? {
        guard let first = episodes.min(by: { ($0.season, $0.number) < ($1.season, $1.number) }) else { return nil }
        if let last, let current = episodes.first(where: { $0.providerID == last.key.providerID }) {
            if !last.watched { return SeriesPlayTarget(episode: current, isContinue: true) }
            if let next = NextEpisode.after(current, in: episodes) {
                return SeriesPlayTarget(episode: next, isContinue: true)
            }
        }
        return SeriesPlayTarget(episode: first, isContinue: false)
    }

    /// "S1:E4".
    nonisolated static func episodeLabel(_ episode: Episode) -> String {
        "S\(episode.season):E\(episode.number)"
    }

    nonisolated private static func episodeRequest(_ episode: Episode, seriesTitle: String?,
                                                   playlistID: UUID) -> PlaybackRequest {
        let label = episodeLabel(episode)
        let title = seriesTitle.map { "\($0) · \(label)" } ?? "\(label) \(episode.title)"
        return PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .series, providerID: episode.providerID,
                                                seriesProviderID: episode.seriesProviderID),
                               title: title, locator: episode.locator, container: episode.container, isLive: false)
    }

    /// Container ur locatorn (Xtream-fältet eller filändelsen i en mall), för motorvalet.
    nonisolated static func container(of locator: StreamLocator) -> String? {
        switch locator {
        case let .xtream(_, _, container):
            return container
        case let .template(template):
            let path = template.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? template
            guard let last = path.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return nil }
            let ext = String(last[last.index(after: dot)...]).lowercased()
            return ext.isEmpty || ext.contains("{") ? nil : ext
        }
    }

    /// Databasläsning utanför huvudaktören; fel blir `ImportError.storageFailed`.
    nonisolated private static func read<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await offMain(work)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportError.storageFailed
        }
    }

    /// Laddar spellistorna. Spellistor som finns i metadata men saknas i databasen (t.ex. för att tvOS rensat
    /// cachen) läggs tillbaka och importeras om, förutsatt att hemligheten finns kvar; annars glöms de.
    func load() async {
        let restored = await restoreMissingPlaylists()
        await reloadPlaylists()
        // Spellistor som fanns i databasen innan metadata infördes.
        let known = Set(metadata.all().map(\.id))
        for p in playlists where !known.contains(p.id) { metadata.save(p) }
        for id in restored { startRefresh(id) }
        await sweepOrphanedCredentials()
    }

    /// Raderar Keychain-poster vars spellista varken finns i metadata eller i databasen (t.ex. kvar efter att en
    /// borttagning avbrutits). Körs bara vid `load()` och rör aldrig spellistor som håller på att läggas till.
    private func sweepOrphanedCredentials() async {
        let credentials = credentials, store = store
        // Läsfel (t.ex. låst Keychain eller databasfel): städa nästa gång i stället.
        guard let ids = try? await offMain(honorsCancellation: false, {
            (try credentials.allPlaylistIDs(), try store.playlists().map(\.id))
        }) else { return }
        let (stored, inDatabase) = ids
        let keep = Set(metadata.all().map(\.id)).union(inDatabase).union(pendingAdds)
        let orphans = stored.filter { !keep.contains($0) }
        guard !orphans.isEmpty else { return }
        _ = try? await offMain(honorsCancellation: false) {
            for id in orphans { try? credentials.delete(for: id) }
        }
    }

    /// Ordning: hemligheten i Keychain → raden i databasen → import. Misslyckas raden tas hemligheten bort igen.
    func addPlaylist(name: String, secret: PlaylistSecret) async {
        let kind: PlaylistSourceKind = switch secret {
        case .xtream: .xtream
        case .m3u: .m3u
        }
        let playlist = Playlist(name: name, kind: kind)
        let id = playlist.id
        let store = store, credentials = credentials
        pendingAdds.insert(id)
        defer { pendingAdds.remove(id) }

        do {
            try await offMain { try credentials.save(secret, for: id) }
        } catch {
            report(error)
            return
        }
        do {
            try await offMain { try store.upsertPlaylist(playlist) }
        } catch {
            try? await offMain(honorsCancellation: false) { try credentials.delete(for: id) }
            report(ImportError.storageFailed)
            return
        }
        metadata.save(playlist)
        await reloadPlaylists()
        await refresh(id)
    }

    /// Kör (om)import och väntar tills den är klar. Pågår redan en import för spellistan väntar vi in den.
    func refresh(_ id: UUID) async {
        await startRefresh(id).value
    }

    /// Startar en import (eller returnerar den som redan pågår) utan att vänta på den.
    @discardableResult
    func startRefresh(_ id: UUID) -> Task<Void, Never> {
        if let running = importTasks[id] { return running }
        let importer = PlaylistImporter(store: store, credentials: credentials, http: http)
        // Uppgiften ärver huvudaktören och kan inte starta förrän `importTasks[id]` är satt nedan.
        let task = Task { [weak self] in
            do {
                for try await phase in importer.run(playlistID: id) {
                    self?.importState[id] = phase
                }
            } catch is CancellationError {
                self?.importState[id] = nil
            } catch {
                self?.importState[id] = nil
                self?.report(error)
            }
            self?.importTasks[id] = nil
            await self?.reloadPlaylists()
        }
        importTasks[id] = task
        return task
    }

    func refreshAll() async {
        let tasks = playlists.map { startRefresh($0.id) }
        for t in tasks { await t.value }
    }

    /// Avbryter pågående import och tar bort Keychain-posten, metadata och alla databasrader. Allt försöks
    /// även om något steg misslyckas.
    func remove(_ id: UUID) async {
        if let running = importTasks[id] {
            running.cancel()
            await running.value
        }
        let store = store, credentials = credentials
        var failure: Error?
        do {
            try await offMain(honorsCancellation: false) { try credentials.delete(for: id) }
        } catch {
            failure = error
        }
        do {
            try await offMain(honorsCancellation: false) { try store.deletePlaylist(id) }
        } catch {
            failure = failure ?? ImportError.storageFailed
        }
        metadata.remove([id])
        userState.remove(playlistID: id)
        importState[id] = nil
        counts[id] = nil
        accountInfo[id] = nil
        if let failure { report(failure) }
        await reloadPlaylists()
    }

    /// Lägger tillbaka metadata-spellistor som saknas i databasen. Returnerar de återställda id:na.
    private func restoreMissingPlaylists() async -> [UUID] {
        let entries = metadata.all()
        guard !entries.isEmpty else { return [] }
        let store = store, credentials = credentials
        do {
            let (restored, orphaned) = try await offMain { () throws -> ([UUID], [UUID]) in
                let existing = Set(try store.playlists().map(\.id))
                var restored: [UUID] = [], orphaned: [UUID] = []
                for entry in entries where !existing.contains(entry.id) {
                    let secret: PlaylistSecret?
                    // Läsfel (t.ex. låst Keychain): behåll posten och försök vid nästa start.
                    do { secret = try credentials.load(for: entry.id) } catch { continue }
                    guard secret != nil else {
                        orphaned.append(entry.id)
                        continue
                    }
                    try store.upsertPlaylist(entry.playlist)
                    restored.append(entry.id)
                }
                return (restored, orphaned)
            }
            metadata.remove(orphaned)
            return restored
        } catch {
            report(ImportError.storageFailed)
            return []
        }
    }

    private func reloadPlaylists() async {
        let store = store
        do {
            let (lists, counts, info) = try await offMain(honorsCancellation: false) {
                let lists = try store.playlists()
                var counts: [UUID: [ContentKind: Int]] = [:]
                var info: [UUID: PlaylistAccountInfo] = [:]
                for p in lists {
                    counts[p.id] = try store.counts(playlistID: p.id)
                    info[p.id] = try store.accountInfo(playlistID: p.id)
                }
                return (lists, counts, info)
            }
            playlists = lists
            self.counts = counts
            accountInfo = info
        } catch {
            report(ImportError.storageFailed)
        }
    }

    private func report(_ error: Error) {
        lastError = UserFacingError.message(for: error)
    }
}

/// En post i "Fortsätt titta".
struct ContinueWatchingItem: Identifiable, Sendable {
    let id: String
    let title: String
    /// "S1:E4" för avsnitt, annars nil.
    let subtitle: String?
    let progressFraction: Double
    let request: PlaybackRequest
    let posterURL: URL?
}

/// Serievyns huvudknapp: "Fortsätt S1:E4" (`isContinue`) eller "Spela S1:E1".
struct SeriesPlayTarget: Equatable, Sendable {
    let episode: Episode
    let isContinue: Bool
}

/// Titeln eller avsnittet finns inte längre i biblioteket.
enum PlaybackLookupError: Error, Sendable {
    case notFound
}

/// Var nästa-avsnitt-leverantören befinner sig.
@MainActor
private final class EpisodeCursor {
    var providerID: String
    init(providerID: String) { self.providerID = providerID }
}
