import Core
import Foundation
import Library
import Metadata
import Observation
import Personal
import Playback
import PlaybackCore
import Providers
import Secrets
import Subtitles
import SyncMapping

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
    /// Vald profil (för en spellista). `nil` visar "Vem tittar?" när en spellista öppnas.
    private(set) var activeProfile: ProfileSession? {
        didSet { applyDownloadSettings() }
    }
    /// Fördelar varje spellistas strömanslutningar (gränsen från `accountInfo`).
    let broker: StreamConnectionBroker
    /// TMDB-metadata. Utan nyckel är tjänsten avstängd (ingen berikning); upptäckt fungerar ändå.
    let metadata: MetadataService
    let discovery: DiscoveryService
    /// Sant när en TMDB-nyckel finns i appens Info.plist.
    let metadataConfigured: Bool
    /// Sant när en OMDb-nyckel finns (IMDb- och Rotten Tomatoes-betyg på detaljsidorna).
    let omdbConfigured: Bool
    /// Ökas vid varje ändring av Min lista eller betyg, så att vyerna läser om knapparnas läge.
    var personalRevision = 0
    /// TMDB-affischer per titel ("spellista|typ|id").
    @ObservationIgnored var tmdbPosters: [String: URL] = [:]
    /// Titlar ("spellista|typ|id") vars affischuppslag inte gav något (ingen matchning eller affisch). Rensas per
    /// spellista av `invalidateMetadataCaches`.
    @ObservationIgnored var tmdbPosterMisses: Set<String> = []
    /// Antal affischuppslag som läste databasen (för tester av cachen).
    @ObservationIgnored var tmdbPosterReads = 0
    /// Ökas när metadata ogiltigförklaras; en läsning som började före ändringen sparas inte i cachen.
    @ObservationIgnored var metadataCacheGeneration = 0
    /// Högsta antal minnda affischmissar; överskrids det töms minnet (en miss kostar bara en läsning att återskapa).
    @ObservationIgnored var tmdbPosterMissLimit = 20_000
    /// Färdiga hero-poster (LRU, 200); se `AppModel+Hero.swift`.
    @ObservationIgnored var heroCache = HeroCache()
    /// Körs efter att `hero` läst databasen, före avgörandet om svaret får lämnas ut och sparas. Bara för tester
    /// (simulerar en uppdatering under läsningen).
    @ObservationIgnored var heroAfterReadHook: (@MainActor () -> Void)?
    /// Antal titlar med TMDB-id i alla spellistor; `nil` tills det räknats (eller utan nyckel).
    private(set) var matchedTitles: Int?
    /// Falskt om TMDB nekat nyckeln under sessionen.
    private(set) var metadataAccepted = true

    /// Nedladdningslagret (iOS/iPadOS). `nil` tills det kopplats in och på tvOS; offlineuppspelning kräver det.
    @ObservationIgnored var downloadStore: DownloadStore?
    #if !os(tvOS)
    /// Bakgrundsnedladdningar (iPhone/iPad). `nil` tills `attachDownloads` anropats (och alltid på tvOS).
    @ObservationIgnored var downloadManager: DownloadManager?
    /// Seriekedja för `DownloadManager.configure`, så att inställningar tillämpas i den ordning de ändrades.
    @ObservationIgnored var downloadConfigTask: Task<Void, Never>?
    /// Nätövervakningen som hanteraren använder; automatiken hämtar bara nästa avsnitt när den säger wifi.
    @ObservationIgnored var downloadNetwork: (any NetworkPolicy)?
    @ObservationIgnored var downloadNetworkTask: Task<Void, Never>?
    /// Offlineläget (banner, tystade nätfel). Delar nätövervakning med nedladdningarna; `nil` tills `attachDownloads`.
    @ObservationIgnored var offlineState: OfflineState?
    /// Städning av nedladdningar för borttagna profiler/spellistor, i den ordning de begärdes.
    @ObservationIgnored var downloadCleanupTask: Task<Void, Never>?
    /// Titlar som passerat sedd-gränsen medan spelaren var öppen; hanteras när spelaren stängts.
    @ObservationIgnored var pendingWatchedDownloads: [PendingWatchedDownload] = []
    /// Spelarvyn är öppen: ingen nedladdning raderas då (filen kan läsas).
    @ObservationIgnored var playerIsOpen = false
    /// En automatisk nästa-avsnitt-kontroll pågår; samtidiga kontroller hoppar över (single-flight).
    @ObservationIgnored var autoNextInFlight = false
    @ObservationIgnored var watchedProcessingTask: Task<Void, Never>?
    #endif
    /// Undertextslagret (filer, förskjutning). `nil` när appen byggts utan det (tillfällig reservdatabas, tester).
    @ObservationIgnored let subtitleStore: SubtitleStore?
    /// OpenSubtitles-tjänsten. `nil` utan API-nyckel (eller utan lager): funktionen är då avstängd.
    @ObservationIgnored let subtitleService: SubtitleService?
    /// Sant när en OpenSubtitles-nyckel finns i appens Info.plist.
    let openSubtitlesConfigured: Bool
    /// Sparade OpenSubtitles-uppgifter (Keychain). Läses bara utanför huvudtråden.
    @ObservationIgnored let subtitleCredentials: any OpenSubtitlesCredentialStore
    /// Sant när OpenSubtitles-uppgifter finns sparade; uppdateras av inloggning, utloggning och `refreshOpenSubtitlesStatus`.
    var openSubtitlesCredentialsSaved = false

    /// Tittarpositioner för den aktiva profilen. Utan aktiv profil ett tillfälligt lager i minnet som aldrig
    /// sparas (och aldrig den gamla globala nyckeln).
    var userState: any UserStateStore { activeProfile?.userState ?? detachedUserState }
    /// Den aktiva profilens uppspelningsinställningar (sparas av profilsessionen). Utan aktiv profil
    /// standardvärden; ändringar ignoreras då.
    var settings: PlaybackSettings {
        get { activeProfile?.settings ?? PlaybackSettings() }
        set { activeProfile?.settings = newValue }
    }
    /// Bibliotekets flikar för den aktiva profilen (Live döljs för barnprofiler).
    var libraryTabs: [LibraryTab] { LibraryTab.visible(isKids: activeProfile?.profile.isKids ?? false) }

    let credentials: CredentialStore
    let http: HTTPClient
    /// Tablålagret (samma instans som `store.epg`) och tablåimporten; exakt en av varje (se `AppModel+Live.swift`).
    @ObservationIgnored let epg: EPGStore
    @ObservationIgnored let epgImporter: EPGImporter
    /// Ökas när en tablåhämtning sparat nya program, så att Live-vyn läser om "Nu/Nästa".
    var epgRevision = 0
    /// Korta tablån (Xtream `get_short_epg`) i minnet, 5 minuter.
    @ObservationIgnored let shortEPGCache = ShortEPGCache()
    /// När tablåhämtningen senast misslyckades eller gav 0 program, per spellista (backoff; `lastFetch` rörs inte då).
    @ObservationIgnored var epgRefreshFailures: [UUID: Date] = [:]
    /// Pågående tablåhämtning per spellista.
    @ObservationIgnored var epgRefreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let playlistMetadata: PlaylistMetadataStore
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let profileStore: any ProfileStore
    @ObservationIgnored let pins: any ProfilePinStore
    @ObservationIgnored let metadataStore: MetadataStore
    @ObservationIgnored private let detachedUserState: any UserStateStore
    /// En session per profil-id, så att varje profil har exakt en instans av sina lager.
    @ObservationIgnored var sessions: [UUID: ProfileSession] = [:]
    /// Ökas när profiler läggs till, ändras eller tas bort (profillagret observeras inte).
    var profilesRevision = 0
    /// Synkkoordinatorn. `nil` i standardbygget (och tills `attachSync` anropats): då finns ingen synk, ingen
    /// transport och inget av det som hör till den; appen beter sig som före fas 7.
    var syncCoordinator: SyncCoordinator?
    /// Hur länge `load()` och `enter` högst väntar på första hämtningen innan en standardprofil skapas.
    @ObservationIgnored var syncInitialPullTimeout: TimeInterval = 10
    /// Spellistor som väntar på bakgrundsberikning, i ordning; körs av en enda uppgift i taget.
    @ObservationIgnored private var metadataQueue: [UUID] = []
    @ObservationIgnored private(set) var metadataTask: Task<Void, Never>?
    /// Identifierar den aktuella bakgrundsuppgiften; en avbruten uppgift får inga fler spellistor ur kön.
    @ObservationIgnored private var metadataRun = UUID()
    /// Spellistan som den aktuella körningen berikar just nu.
    @ObservationIgnored private var metadataCurrent: UUID?
    /// Senast avbrutna körning; nästa körning väntar in den innan den börjar.
    @ObservationIgnored private(set) var cancelledMetadataTask: Task<Void, Never>?
    /// Felaktiga PIN-försök i rad per profil och hur länge profilen är spärrad. Sparas i UserDefaults, så att en
    /// omstart inte nollställer spärren.
    @ObservationIgnored private let pinLockoutStore: PinLockoutStore
    @ObservationIgnored let now: @Sendable () -> Date
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    /// Sant när databasen på disk inte kunde öppnas och appen kör på en tillfällig databas i minnet. Då är
    /// databasen tom och kan inte avgöra vilka Keychain-poster som är föräldralösa.
    @ObservationIgnored let usesFallbackDatabase: Bool
    /// Pågående avsnittshämtningar; samtidiga anrop för samma serie delar en hämtning.
    @ObservationIgnored private var episodeTasks: [EpisodeTaskKey: Task<[Episode], Error>] = [:]
    /// Spellistor som håller på att läggas till; deras Keychain-poster får inte städas bort.
    @ObservationIgnored private var pendingAdds: Set<UUID> = []

    private struct EpisodeTaskKey: Hashable {
        let playlistID: UUID
        let seriesProviderID: String
    }

    /// Kör `ProfileMigration.migrateLegacy` för alla kända spellistor (databasen och metadata) innan något
    /// profillager skapas.
    /// - Parameter userState: lagret som används när ingen profil är aktiv (tester). Utelämnas blir det ett
    ///   tillfälligt lager i minnet.
    /// - Parameter usesFallbackDatabase: sant när `store` är den tillfälliga reservdatabasen (se `live()`).
    /// - Parameter pins: PIN-lager; produktion skickar `KeychainProfilePinStore`.
    /// - Parameter tmdbToken: TMDB:s läs-token. Tom eller ett ej ersatt `$(…)` räknas som saknad.
    /// - Parameter omdbKey: OMDb-nyckel (samma regler). Bara med nyckel hämtas IMDb- och Rotten Tomatoes-betyg.
    /// - Parameter openSubtitlesKey: OpenSubtitles API-nyckel (samma regler som `tmdbToken`). Utan nyckel eller
    ///   `subtitleStore` är undertextsfunktionen avstängd.
    /// - Parameter subtitleCredentials: lager för OpenSubtitles-uppgifter; produktion skickar `KeychainOpenSubtitlesStore`.
    /// - Parameter epg: tablålagret; utelämnas används `store.epg`. Ska vara databasens enda instans.
    /// - Parameter epgImporter: tablåimporten; utelämnas byggs den av `store`, `epg`, `credentials` och `http`.
    init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient, defaults: UserDefaults = .standard,
         userState: (any UserStateStore)? = nil, usesFallbackDatabase: Bool = false,
         profileStore: (any ProfileStore)? = nil, pins: any ProfilePinStore = InMemoryProfilePinStore(),
         tmdbToken: String? = nil, omdbKey: String? = nil, openSubtitlesKey: String? = nil,
         subtitleStore: SubtitleStore? = nil,
         subtitleCredentials: any OpenSubtitlesCredentialStore = InMemoryOpenSubtitlesCredentialStore(),
         broker: StreamConnectionBroker = StreamConnectionBroker(),
         epg: EPGStore? = nil, epgImporter: EPGImporter? = nil,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        self.store = store
        let epgStore = epg ?? store.epg
        self.epg = epgStore
        self.epgImporter = epgImporter ?? EPGImporter(store: store, epg: epgStore, credentials: credentials, http: http)
        self.usesFallbackDatabase = usesFallbackDatabase
        self.credentials = credentials
        self.http = http
        let playlistMetadata = PlaylistMetadataStore(defaults: defaults)
        self.playlistMetadata = playlistMetadata
        self.defaults = defaults
        self.detachedUserState = userState ?? InMemoryUserStateStore()
        let profileStore = profileStore ?? UserDefaultsProfileStore(defaults: defaults)
        self.profileStore = profileStore
        self.pins = pins
        self.pinLockoutStore = PinLockoutStore(defaults: defaults)
        self.broker = broker
        let metadataStore = MetadataStore(library: store)
        let token = Self.usableToken(tmdbToken)
        self.metadataStore = metadataStore
        self.metadataConfigured = token != nil
        let omdb = Self.usableToken(omdbKey)
        self.omdbConfigured = omdb != nil
        self.metadata = MetadataService(store: metadataStore, library: store,
                                        client: token.map { TMDBClient(token: $0, http: http) },
                                        omdb: omdb.map { OMDbClient(apiKey: $0, http: http) })
        self.discovery = DiscoveryService(library: store, metadata: metadataStore)
        let osKey = Self.usableToken(openSubtitlesKey)
        self.openSubtitlesConfigured = osKey != nil
        self.subtitleStore = subtitleStore
        self.subtitleCredentials = subtitleCredentials
        if let osKey, let subtitleStore {
            self.subtitleService = SubtitleService(
                client: OpenSubtitlesClient(apiKey: osKey, http: http), store: subtitleStore,
                credentials: subtitleCredentials)
        } else {
            self.subtitleService = nil
        }
        // Före varje profillager: flytta globala positioner/inställningar till "Profil 1" per spellista.
        let known = Set((try? store.playlists().map(\.id)) ?? []).union(playlistMetadata.all().map(\.id))
        ProfileMigration.migrateLegacy(defaults: defaults, playlists: known.sorted { $0.uuidString < $1.uuidString },
                                       profiles: profileStore)
    }

    /// Token ur Info.plist: tom eller ett ej ersatt `$(…)`-värde räknas som saknad.
    nonisolated static func usableToken(_ raw: String?) -> String? {
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              !token.contains("$(") else { return nil }
        return token
    }

    /// Produktionsuppsättning: databas på disk, Keychain och `URLSessionHTTPClient()` med paketets
    /// standardvärden (30 s per förfrågan, 600 s per resurs – räcker för stora kataloger).
    static func live() -> AppModel {
        let http = URLSessionHTTPClient()
        let credentials = KeychainCredentialStore()
        let pins = KeychainProfilePinStore()
        let token = Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String
        let omdbKey = Bundle.main.object(forInfoDictionaryKey: "OMDbAPIKey") as? String
        let openSubtitlesKey = Bundle.main.object(forInfoDictionaryKey: "OpenSubtitlesAPIKey") as? String
        let subtitleCredentials = KeychainOpenSubtitlesStore()
        do {
            let db = try LibraryLocation.open()
            let subtitles = SubtitleStore(db: db, directory: LibraryLocation.subtitlesDirectory())
            let model = AppModel(store: LibraryStore(db: db), credentials: credentials, http: http,
                                 pins: pins, tmdbToken: token, omdbKey: omdbKey, openSubtitlesKey: openSubtitlesKey,
                                 subtitleStore: subtitles, subtitleCredentials: subtitleCredentials)
            #if !os(tvOS)
            let downloads = LibraryLocation.downloadsDirectory()
            model.attachDownloads(
                store: DownloadStore(db: db, directory: downloads),
                transport: BackgroundDownloadTransport(stagingDirectory: LibraryLocation.downloadsStagingDirectory()),
                network: PathNetworkPolicy(),
                freeSpace: { DownloadManager.availableBytes(at: downloads) })
            #endif
            model.attachSyncIfAvailable()
            return model
        } catch {
            // Sista utväg: en tillfällig databas så att appen ändå startar. Spellistorna återställs från
            // metadata i `load()`.
            // swiftlint:disable:next force_try
            let model = AppModel(store: LibraryStore(db: try! AppDatabase.inMemory()), credentials: credentials,
                                 http: http, usesFallbackDatabase: true, pins: pins, tmdbToken: token,
                                 omdbKey: omdbKey, openSubtitlesKey: openSubtitlesKey,
                                 subtitleCredentials: subtitleCredentials)
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
        let loaded = try await task.value
        startDetailsRefetchIfNeeded(key: key, hasEpisodes: !loaded.isEmpty)
        return loaded
    }

    /// Räknas upp när en omhämtning skrivit nya uppgifter (stillbild, beskrivning, längd) för en serie; vyer som visar
    /// avsnitt läser då om dem.
    private(set) var episodeDetailsRevision = 0
    /// Serier vars omhämtning redan försökts under den här körningen (lyckad eller inte): ett misslyckande
    /// (offline, 4xx) upprepas inte vid varje öppning.
    @ObservationIgnored private var detailsRefetchAttempted: Set<EpisodeTaskKey> = []
    @ObservationIgnored private var detailsRefetchTasks: [EpisodeTaskKey: Task<Void, Never>] = [:]

    /// Avsnitt som lagrats före migreringen v5 saknar stillbild, beskrivning och längd. Listan returneras direkt ur
    /// databasen; omhämtningen sker i bakgrunden, högst en gång per serie och körning, och de lagrade raderna rörs
    /// bara av en lyckad hämtning.
    private func startDetailsRefetchIfNeeded(key: EpisodeTaskKey, hasEpisodes: Bool) {
        guard hasEpisodes, detailsRefetchAttempted.insert(key).inserted else { return }
        let store = store, credentials = credentials, http = http
        detailsRefetchTasks[key] = Task { [weak self] in
            let changed = await Task.detached(priority: .utility) {
                await Self.refetchEpisodeDetails(seriesProviderID: key.seriesProviderID, playlistID: key.playlistID,
                                                 store: store, credentials: credentials, http: http)
            }.value
            guard let self else { return }
            if changed { self.episodeDetailsRevision += 1 }
            self.detailsRefetchTasks[key] = nil
        }
    }

    /// Väntar in en pågående omhämtning (tester).
    func awaitDetailsRefetch(for seriesProviderID: String, playlistID: UUID) async {
        await detailsRefetchTasks[EpisodeTaskKey(playlistID: playlistID, seriesProviderID: seriesProviderID)]?.value
    }

    /// Hämtar om en Xtream-serie vars lagrade avsnitt aldrig skrivits med uppgifter. Sant när raderna uppdaterats.
    /// Alla fel (nät, leverantör, hemlighet, lagring) lämnar de lagrade raderna orörda; en tom lista markerar bara.
    nonisolated private static func refetchEpisodeDetails(seriesProviderID: String, playlistID: UUID,
                                                          store: LibraryStore, credentials: CredentialStore,
                                                          http: HTTPClient) async -> Bool {
        guard let kind = try? store.playlists().first(where: { $0.id == playlistID })?.kind, kind == .xtream,
              (try? store.episodesNeedDetails(playlistID: playlistID, seriesProviderID: seriesProviderID)) == true,
              case let .xtream(server, username, password)? = try? credentials.load(for: playlistID),
              let fetched = try? await XtreamClient(server: server, username: username, password: password,
                                                    http: http).episodes(seriesID: seriesProviderID),
              !Task.isCancelled else { return false }
        if fetched.isEmpty {
            try? store.markEpisodeDetailsFetched(playlistID: playlistID, seriesProviderID: seriesProviderID)
            return false
        }
        return (try? store.upsertEpisodes(fetched, seriesProviderID: seriesProviderID, playlistID: playlistID,
                                          now: Date())) != nil
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
    /// Med `startFromBeginning` ("Från början") blir `startAt` 0, så att sparad position inte används.
    func playbackRequest(kind: ContentKind, providerID: String, seriesProviderID: String?,
                         playlistID: UUID, startFromBeginning: Bool = false) async throws -> PlaybackRequest {
        // Barnprofil: bara titlar med känd åldersgräns som klarar barnfiltret (även via djuplänk eller en
        // inaktuell rad). Live och avsnitt utan serie nekas.
        if activeProfile?.profile.isKids == true {
            let key = ProgressKey(playlistID: playlistID, kind: kind, providerID: providerID,
                                  seriesProviderID: seriesProviderID)
            let discovery = discovery
            let allowed = (try? await offMain { Self.allowedForKids(discovery, key: key) }) ?? false
            guard allowed else { throw PlaybackLookupError.notAllowed }
        }
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
        if kind != .live {
            request.startAt = DetailPresentation.startPosition(progress: userState.progress(for: request.key),
                                                               fromStart: startFromBeginning)
        }
        return request
    }

    /// Live: bästa varianten i gruppen för skärmen, utan startposition. `nil` i barnläge (djupförsvar: Live-fliken
    /// är redan dold för barnprofiler, och utan vald profil är läget stängt som standard).
    func liveRequest(group: ChannelGroup, playlistID: UUID, displaySupportsHDR: Bool) -> PlaybackRequest? {
        liveRequest(group: group, variant: group.preferred(displaySupportsHDR: displaySupportsHDR),
                    playlistID: playlistID)
    }

    /// Live: en bestämd variant av gruppen (kvalitetsmenyn). `nil` i barnläge, som `liveRequest(group:…)`.
    func liveRequest(group: ChannelGroup, variant stream: LiveStream, playlistID: UUID) -> PlaybackRequest? {
        guard !kidsRestricted else { return nil }
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

    /// Högsta antal poster i "Fortsätt titta".
    nonisolated static let continueWatchingLimit = 20

    /// "Fortsätt titta" för en spellista, nyast först. Poster vars titel eller avsnitt inte längre finns hoppas
    /// över. Läser bara databasen (hämtar inga avsnitt). Med `kind` visas bara filmer (`.movie`) eller
    /// avsnitt (`.series`), som i respektive flik; filtret tillämpas före gränsen på 20.
    func continueWatching(playlistID: UUID, kind: ContentKind? = nil) async -> [ContinueWatchingItem] {
        let entries: [WatchProgress]
        if activeProfile?.profile.isKids == true {
            // Barnprofil: åldersfiltret före gränsen, stängt som standard.
            let all = Self.continueWatchingEntries(userState.continueWatching(playlistID: playlistID, limit: .max),
                                                   kind: kind)
            let discovery = discovery, limit = Self.continueWatchingLimit
            entries = (try? await offMain {
                Array(all.filter { Self.allowedForKids(discovery, key: $0.key) }.prefix(limit))
            }) ?? []
        } else {
            entries = Self.continueWatchingEntries(userState, playlistID: playlistID, kind: kind)
        }
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

    /// Profilens "Fortsätt titta"-poster av typen `kind` (nil = alla), nyast först och högst
    /// `continueWatchingLimit`. Typfiltret tillämpas före gränsen, så att t.ex. många serier inte tränger ut
    /// filmerna i Filmer-fliken.
    nonisolated static func continueWatchingEntries(_ state: any UserStateStore, playlistID: UUID,
                                                    kind: ContentKind?) -> [WatchProgress] {
        let all = state.continueWatching(playlistID: playlistID, limit: .max)
        return Array(continueWatchingEntries(all, kind: kind).prefix(continueWatchingLimit))
    }

    /// Får posten (film, eller avsnitt via sin serie) visas för en barnprofil? Live, okända titlar och titlar
    /// utan åldersgräns: nej. Läser databasen; anropa utanför huvudaktören.
    nonisolated static func allowedForKids(_ discovery: DiscoveryService, key: ProgressKey) -> Bool {
        let kind: ContentKind
        let id: String
        if let series = key.seriesProviderID, key.kind == .series {
            kind = .series
            id = series
        } else if key.kind == .movie {
            kind = .movie
            id = key.providerID
        } else {
            return false
        }
        return (try? discovery.isAllowedForKids(playlistID: key.playlistID, kind: kind, providerID: id)) ?? false
    }

    /// Filtrerar "Fortsätt titta"-poster på typ (nil = alla).
    nonisolated static func continueWatchingEntries(_ entries: [WatchProgress], kind: ContentKind?) -> [WatchProgress] {
        guard let kind else { return entries }
        return entries.filter { $0.key.kind == kind }
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
        syncCoordinator?.start()
        // Fjärrraderade spellistor lämnas åt städningen innan något nedan kan återuppliva dem.
        if syncCoordinator != nil { handleRemotePlaylistDeletions() }
        let restored = await restoreMissingPlaylists()
        await reloadPlaylists()
        // Spellistor som fanns i databasen innan metadata infördes.
        // Id:n med gravsten (t.ex. fjärrraderade som ännu inte städats) återupplivas aldrig här.
        let known = Set(playlistMetadata.allIncludingTombstones().map(\.id))
        for p in playlists where !known.contains(p.id) {
            playlistMetadata.save(p)
            noteSyncChange(SyncMapper.playlistID(p.id))
        }
        // Med synk på väntar vi (högst `syncInitialPullTimeout`) på molnets profiler, så att en ny enhet inte
        // skapar en dubblett av "Profil 1". Utan synk görs ingenting extra här.
        if let sync = syncCoordinator,
           playlists.contains(where: { profileStore.profiles(playlistID: $0.id).isEmpty }) {
            await sync.waitForInitialPull(timeout: syncInitialPullTimeout)
        }
        for p in playlists { ensureDefaultProfile(playlistID: p.id) }
        for id in restored { startRefresh(id) }
        await sweepOrphanedCredentials()
        await purgeOrphanedSubtitles()
        await purgeDownloadsOfRemovedProfiles()
        scheduleMetadata(playlists.map(\.id))
    }

    /// Tar bort undertextfiler som saknar rad i databasen (och tvärtom). Lokal städning utan nätverk, så den
    /// gäller även i barnläge. Fel ignoreras: nästa start eller borttagning försöker igen.
    func purgeOrphanedSubtitles() async {
        guard !usesFallbackDatabase, let subtitleStore else { return }
        _ = try? await offMain(honorsCancellation: false) { try subtitleStore.purgeOrphans() }
    }

    /// Raderar Keychain-poster vars spellista varken finns i metadata eller i databasen (t.ex. kvar efter att en
    /// borttagning avbrutits). Körs bara vid `load()` och rör aldrig spellistor som håller på att läggas till.
    private func sweepOrphanedCredentials() async {
        // Reservdatabasen i minnet är tom: alla poster skulle se föräldralösa ut. Städa aldrig då.
        guard !usesFallbackDatabase else { return }
        let credentials = credentials, store = store
        // Läsfel (t.ex. låst Keychain eller databasfel): städa nästa gång i stället.
        guard let ids = try? await offMain(honorsCancellation: false, {
            (try credentials.allPlaylistIDs(), try store.playlists().map(\.id))
        }) else { return }
        let (stored, inDatabase) = ids
        let keep = Set(playlistMetadata.all().map(\.id)).union(inDatabase).union(pendingAdds)
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
        playlistMetadata.save(playlist)
        noteSyncChange(SyncMapper.playlistID(id))
        ensureDefaultProfile(playlistID: id)
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
            var succeeded = false
            do {
                for try await phase in importer.run(playlistID: id) {
                    self?.importState[id] = phase
                }
                succeeded = true
            } catch is CancellationError {
                self?.importState[id] = nil
            } catch {
                self?.importState[id] = nil
                self?.report(error)
            }
            self?.importTasks[id] = nil
            // Kanalerna kan ha ändrats: tablåns koppling görs om vid nästa uppdatering i stället för efter 12 timmar.
            if succeeded { await self?.resetEPGFetchTime(playlistID: id) }
            // Katalogen kan ha ändrats: upptäcktens kandidater byggs om vid nästa läsning.
            self?.discovery.invalidate(playlistID: id)
            self?.invalidateMetadataCaches(playlistID: id)
            await self?.reloadPlaylists()
            if succeeded { self?.scheduleMetadata([id]) }
        }
        importTasks[id] = task
        return task
    }

    func refreshAll() async {
        let tasks = playlists.map { startRefresh($0.id) }
        for t in tasks { await t.value }
    }

    /// Borttagning av en spellista från gränssnittet. Samma regel och spärr som spellistans profilhantering:
    /// aldrig medan en barnprofil är aktiv (`notAllowed`); fri bara när den aktiva profilen är en vuxenprofil i
    /// spellistan; annars krävs en vuxen-PIN om spellistan har en vuxenprofil med PIN (`adultPinRequired`,
    /// `wrongPin`, `tooManyAttempts`), och utan sådan PIN är borttagningen fri.
    func remove(playlistID: UUID, adultPin: String? = nil) async throws {
        guard canManageProfiles(playlistID: playlistID) else { throw ProfileError.notAllowed }
        try requireAdultPin(playlistID: playlistID, adultPin)
        await remove(playlistID)
    }

    /// Avbryter pågående import och tar bort Keychain-posten, metadata och alla databasrader. Allt försöks
    /// även om något steg misslyckas. Utan PIN-kontroll: gränssnittet använder `remove(playlistID:adultPin:)`.
    func remove(_ id: UUID) async {
        // En pågående berikning av spellistan avbryts innan raderna försvinner.
        stopMetadata(for: id)
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
        await purgeOrphanedSubtitles()
        // Användarens borttagning: gravsten för spellistan och dess profiler (före att något töms).
        syncCoordinator?.playlistWillBeDeleted(id)
        playlistMetadata.remove([id])
        detachedUserState.remove(playlistID: id)
        for profile in profileStore.profiles(playlistID: id) { purgeProfile(profile.id) }
        profilesRevision += 1
        discovery.invalidate(playlistID: id)
        invalidateMetadataCaches(playlistID: id)
        importState[id] = nil
        counts[id] = nil
        accountInfo[id] = nil
        if let failure { report(failure) }
        await reloadPlaylists()
    }

    /// Lägger tillbaka metadata-spellistor som saknas i databasen. Returnerar de återställda id:na.
    private func restoreMissingPlaylists() async -> [UUID] {
        let entries = playlistMetadata.all()
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
                        // Spellista mottagen via synk väntar på inloggning: släpp den inte.
                        if !entry.fromRemote { orphaned.append(entry.id) }
                        continue
                    }
                    try store.upsertPlaylist(entry.playlist)
                    restored.append(entry.id)
                }
                return (restored, orphaned)
            }
            // Lokal städning: hårdradera utan gravsten (en gravsten skulle synkas som radering överallt).
            playlistMetadata.discard(orphaned)
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
            // Okänd gräns (`nil`) behandlas som 1 av vakten.
            for p in lists { await broker.setLimit(info[p.id]?.maxConnections, playlistID: p.id) }
        } catch {
            report(ImportError.storageFailed)
        }
    }

    func report(_ error: Error) {
        presentError(error)
    }

    // MARK: - Profiler

    /// Spellistans profiler, äldst först.
    func profiles(for playlistID: UUID) -> [Profile] {
        _ = profilesRevision
        return profileStore.profiles(playlistID: playlistID)
    }

    /// Ny profil. Utan `pin` (standard) väljs profilen direkt utan PIN-fråga; med `pin` (exakt fyra siffror)
    /// krävs koden vid val.
    @discardableResult
    func addProfile(playlistID: UUID, name: String, avatar: String, isKids: Bool = false,
                    pin: String? = nil, adultPin: String? = nil) throws -> Profile {
        guard canManageProfiles(playlistID: playlistID) else { throw ProfileError.notAllowed }
        if let pin, !isValidPin(pin) { throw ProfileError.invalidPin }
        try requireAdultPin(playlistID: playlistID, adultPin)
        let profile = Profile(playlistID: playlistID, name: Self.profileName(name), avatar: avatar, isKids: isKids,
                              hasPin: pin != nil)
        if let pin { try pins.setPin(pin, profileID: profile.id) }
        profileStore.save(profile)
        noteSyncChange(SyncMapper.profileID(profile.id))
        profilesRevision += 1
        return profile
    }

    /// Sant om spellistans profiler får läggas till, ändras och tas bort: aldrig medan en barnprofil är aktiv
    /// (oavsett spellista; då finns bara "Byt profil"). Utan en vuxenprofil från just den spellistan aktiv kan
    /// dessutom en vuxen-PIN krävas (`adultPinRequired`).
    func canManageProfiles(playlistID: UUID) -> Bool { activeProfile?.profile.isKids != true }

    /// Den aktiva profilen är en vuxenprofil i spellistan; bara då är spellistans profilhantering fri utan
    /// vuxen-PIN. En aktiv profil i en annan spellista räknas inte.
    private func hasQualifyingActiveProfile(playlistID: UUID) -> Bool {
        guard let active = activeProfile?.profile else { return false }
        return active.playlistID == playlistID && !active.isKids
    }

    /// Spellistans vuxenprofiler med PIN. Deras koder vaktar profilhanteringen när ingen profil är aktiv.
    func adultPinProfiles(playlistID: UUID) -> [Profile] {
        _ = profilesRevision
        return profileStore.profiles(playlistID: playlistID).filter { !$0.isKids && $0.hasPin }
    }

    /// Kräver profilhanteringen för spellistan en vuxen-PIN just nu? Ja när ingen vuxenprofil från spellistan är
    /// aktiv (t.ex. efter "Byt profil" från en barnprofil, eller med en profil från en annan spellista aktiv) och
    /// spellistan har en vuxenprofil med PIN. Har ingen vuxenprofil PIN är hanteringen fri (ägarens val).
    func adultPinRequired(playlistID: UUID) -> Bool {
        !hasQualifyingActiveProfile(playlistID: playlistID) && !adultPinProfiles(playlistID: playlistID).isEmpty
    }

    /// Kontrollerar en vuxen-PIN (koden för någon av spellistans vuxenprofiler med PIN) med samma spärr som vid
    /// val. Godtas alltid när ingen vuxen-PIN krävs.
    func verifyAdultPin(playlistID: UUID, pin: String) async throws {
        guard !hasQualifyingActiveProfile(playlistID: playlistID) else { return }
        let guards = adultPinProfiles(playlistID: playlistID)
        guard !guards.isEmpty else { return }
        let ids = try unlockedGuardIDs(guards)
        let pins = pins
        let matched = try? await offMain(honorsCancellation: false) { () throws -> UUID? in
            ids.first { (try? pins.verify(pin, profileID: $0)) ?? false }
        }
        try recordAdultPinResult(matched ?? nil, ids: ids)
    }

    /// Hantering utan aktiv profil: kräver en giltig vuxen-PIN när spellistan har en vuxenprofil med PIN.
    private func requireAdultPin(playlistID: UUID, _ adultPin: String?) throws {
        guard !hasQualifyingActiveProfile(playlistID: playlistID) else { return }
        let guards = adultPinProfiles(playlistID: playlistID)
        guard !guards.isEmpty else { return }
        let ids = try unlockedGuardIDs(guards)
        guard let adultPin else { throw ProfileError.adultPinRequired }
        let matched = ids.first { (try? pins.verify(adultPin, profileID: $0)) ?? false }
        try recordAdultPinResult(matched, ids: ids)
    }

    /// Vuxenprofilerna vars PIN inte är spärrad just nu; `tooManyAttempts` om alla är spärrade.
    private func unlockedGuardIDs(_ guards: [Profile]) throws -> [UUID] {
        var ids: [UUID] = []
        for profile in guards {
            do {
                try checkPinLockout(profile.id)
                ids.append(profile.id)
            } catch {}
        }
        guard !ids.isEmpty else { throw ProfileError.tooManyAttempts }
        return ids
    }

    /// Rätt kod nollställer den profilens räknare; fel kod räknas mot alla prövade vuxenprofiler.
    private func recordAdultPinResult(_ matched: UUID?, ids: [UUID]) throws {
        if let matched {
            try recordPinResult(true, profileID: matched)
            return
        }
        var failure: Error = ProfileError.wrongPin
        for id in ids {
            do { try recordPinResult(false, profileID: id) } catch { failure = error }
        }
        throw failure
    }

    /// Sparar namn, avatar och barnprofil. `pin` sätter, behåller eller tar bort PIN-koden. En profil som har
    /// PIN kräver nuvarande kod (`currentPin`) för varje ändring, även för att ta bort PIN eller barnprofil.
    /// Utan aktiv profil krävs dessutom en vuxen-PIN (`adultPin`) om spellistan har en vuxenprofil med PIN.
    func updateProfile(_ profile: Profile, pin: PinChange = .keep, currentPin: String? = nil,
                       adultPin: String? = nil) throws {
        guard var stored = storedProfile(profile) else { throw ProfileError.notFound }
        guard canManageProfiles(playlistID: stored.playlistID) else { throw ProfileError.notAllowed }
        try requireAdultPin(playlistID: stored.playlistID, adultPin)
        try requireCurrentPin(stored, currentPin)
        stored.name = Self.profileName(profile.name)
        stored.avatar = profile.avatar
        stored.isKids = profile.isKids
        switch pin {
        case .keep:
            break
        case let .set(code):
            guard isValidPin(code) else { throw ProfileError.invalidPin }
            try pins.setPin(code, profileID: stored.id)
            stored.hasPin = true
        case .remove:
            // Utan lokal PIN går skyddet inte att häva härifrån.
            if profileNeedsPin(stored.id) { throw ProfileError.pinRequiredOnThisDevice }
            try pins.removePin(profileID: stored.id)
            stored.hasPin = false
        }
        profileStore.save(stored)
        if pin != .keep { syncCoordinator?.profilePinChanged(stored.id) }
        noteSyncChange(SyncMapper.profileID(stored.id))
        sessions[stored.id]?.update(stored)
        profilesRevision += 1
    }

    /// Tar bort profilen med dess positioner, inställningar, Min lista/betyg och PIN. Var den aktiv visas
    /// "Vem tittar?". Spellistan får en ny standardprofil om ingen profil återstår. En profil med PIN kräver
    /// nuvarande kod.
    func deleteProfile(_ profile: Profile, currentPin: String? = nil, adultPin: String? = nil) throws {
        // Den sparade profilen (inte anroparens kopia) avgör spellistan för kontrollerna.
        guard let stored = storedProfile(profile) else { throw ProfileError.notFound }
        guard canManageProfiles(playlistID: stored.playlistID) else { throw ProfileError.notAllowed }
        try requireAdultPin(playlistID: stored.playlistID, adultPin)
        try requireCurrentPin(stored, currentPin)
        purgeProfile(stored.id)
        ensureDefaultProfile(playlistID: stored.playlistID)
        profilesRevision += 1
    }

    /// Väljer profilen. En profil utan PIN väljs direkt (`pin` ignoreras); för en profil med PIN kastas
    /// `ProfileError.wrongPin` om koden saknas eller är fel. Efter `maxPinFailures` fel i rad avvisas alla
    /// försök för profilen med `ProfileError.tooManyAttempts` i `pinLockout` sekunder; rätt kod nollställer.
    func select(profile: Profile, pin: String?) async throws {
        guard let stored = storedProfile(profile) else { throw ProfileError.notFound }
        if profileNeedsPin(stored.id) { throw ProfileError.pinRequiredOnThisDevice }
        if stored.hasPin { try await verifyProfilePin(stored, pin: pin) }
        activate(stored)
    }

    /// Kontrollerar profilens PIN (t.ex. innan redigeraren låses upp) med samma spärr som vid val. Kastar
    /// `wrongPin` eller `tooManyAttempts`; en profil utan PIN godtas alltid.
    func verifyProfilePin(_ profile: Profile, pin: String?) async throws {
        guard let stored = storedProfile(profile) else { throw ProfileError.notFound }
        guard stored.hasPin else { return }
        let id = stored.id
        try checkPinLockout(id)
        guard let pin else { throw ProfileError.wrongPin }
        let pins = pins
        let ok = (try? await offMain(honorsCancellation: false) { try pins.verify(pin, profileID: id) }) ?? false
        try recordPinResult(ok, profileID: id)
    }

    /// Ändring eller borttagning: en profil med PIN kräver rätt nuvarande kod (med spärren).
    private func requireCurrentPin(_ stored: Profile, _ currentPin: String?) throws {
        guard stored.hasPin else { return }
        try checkPinLockout(stored.id)
        guard let currentPin else { throw ProfileError.wrongPin }
        let ok = (try? pins.verify(currentPin, profileID: stored.id)) ?? false
        try recordPinResult(ok, profileID: stored.id)
    }

    private func checkPinLockout(_ id: UUID) throws {
        guard let until = pinLockoutStore.entry(id)?.lockedUntil else { return }
        if now() < until { throw ProfileError.tooManyAttempts }
        pinLockoutStore.set(nil, for: id)
    }

    /// Rätt kod nollställer räknaren; fel kod räknas, och efter `maxPinFailures` spärras profilen. Har en spärr
    /// hunnit sättas medan koden kontrollerades (t.ex. under en `await`) behålls den: resultatet blir
    /// `tooManyAttempts` och spärren skrivs aldrig över.
    private func recordPinResult(_ ok: Bool, profileID id: UUID) throws {
        if let until = pinLockoutStore.entry(id)?.lockedUntil, now() < until { throw ProfileError.tooManyAttempts }
        guard !ok else {
            pinLockoutStore.set(nil, for: id)
            return
        }
        let failures = (pinLockoutStore.entry(id)?.failures ?? 0) + 1
        if failures >= Self.maxPinFailures {
            let until = now().addingTimeInterval(Self.pinLockout)
            pinLockoutStore.set(PinLockoutStore.Entry(failures: 0, lockedUntil: until), for: id)
        } else {
            pinLockoutStore.set(PinLockoutStore.Entry(failures: failures, lockedUntil: nil), for: id)
        }
        throw ProfileError.wrongPin
    }

    /// Felaktiga PIN-försök i rad innan profilen spärras.
    nonisolated static let maxPinFailures = 5
    /// Spärrtid i sekunder efter för många fel.
    nonisolated static let pinLockout: TimeInterval = 30

    /// Spellistan öppnas: behåll en aktiv profil för samma spellista, annars välj en ensam profil utan PIN
    /// automatiskt. Med flera profiler (eller PIN) förblir `activeProfile` nil och "Vem tittar?" visas.
    func enter(playlistID: UUID) {
        if activeProfile?.profile.playlistID == playlistID { return }
        activeProfile = nil
        if let sync = syncCoordinator, sync.isAwaitingInitialPull,
           profileStore.profiles(playlistID: playlistID).isEmpty {
            // Molnets profiler kan vara på väg: skapa ingen standardprofil förrän hämtningen är klar (eller tiden gått).
            let timeout = syncInitialPullTimeout
            Task { [weak self] in
                await sync.waitForInitialPull(timeout: timeout)
                self?.enter(playlistID: playlistID)
            }
            return
        }
        ensureDefaultProfile(playlistID: playlistID)
        let list = profileStore.profiles(playlistID: playlistID)
        if list.count == 1, !list[0].hasPin, !profileNeedsPin(list[0].id) { activate(list[0]) }
    }

    /// "Byt profil": visar "Vem tittar?" nästa gång biblioteket visas.
    func switchProfile() {
        activeProfile = nil
    }

    private func activate(_ profile: Profile) {
        guard !profileNeedsPin(profile.id) else { return }
        let session: ProfileSession
        if let cached = sessions[profile.id] {
            cached.update(profile)
            session = cached
        } else {
            session = ProfileSession(profile: profile, defaults: defaults)
            session.settingsDidChange = { [weak self, weak session] in
                // Bara den aktiva profilens inställningar styr hanteraren.
                guard let self, let session, self.activeProfile === session else { return }
                self.applyDownloadSettings()
            }
            installSyncHandler(on: session)
            sessions[profile.id] = session
        }
        activeProfile = session
        profileStore.setLastUsed(profile.id, playlistID: profile.playlistID)
    }

    private func storedProfile(_ profile: Profile) -> Profile? {
        profileStore.profiles(playlistID: profile.playlistID).first { $0.id == profile.id }
    }

    /// Varje spellista har minst en profil (utan PIN).
    func ensureDefaultProfile(playlistID: UUID) {
        guard profileStore.profiles(playlistID: playlistID).isEmpty else { return }
        // Fjärrraderad spellista som väntar på städning får ingen ny profil.
        if syncCoordinator != nil, playlistMetadata.pendingRemoteDeletions().contains(playlistID) { return }
        let profile = Profile(playlistID: playlistID, name: String(localized: "Profile 1"),
                              avatar: ProfileAvatars.all[0])
        profileStore.save(profile)
        noteSyncChange(SyncMapper.profileID(profile.id))
        profilesRevision += 1
    }

    /// Tar bort profilens lokala data. `userInitiated` är falskt när borttagningen kommer från synken (då finns
    /// gravstenen redan och ingen ny ska skapas).
    func purgeProfile(_ id: UUID, userInitiated: Bool = true) {
        // Före allt annat: synken noterar användarens radering medan profilens data ännu finns.
        if userInitiated { syncCoordinator?.profileWillBeDeleted(id) }
        // Först: sessionens lager slutar skriva, så att en pågående uppspelning (t.ex. bild-i-bild) inte
        // återskapar nycklarna nedan.
        sessions[id]?.invalidate()
        pinLockoutStore.set(nil, for: id)
        profileStore.delete(id: id)
        for key in [ProfileKeys.progress(id), ProfileKeys.settings(id), ProfileKeys.personal(id)] {
            defaults.removeObject(forKey: key)
        }
        // Ett misslyckat Keychain-anrop lämnar bara en oåtkomlig hash under ett id som inte längre används.
        try? pins.removePin(profileID: id)
        sessions[id] = nil
        if activeProfile?.profile.id == id { activeProfile = nil }
        // Profilens nedladdningar (rader, filer, bilder) tas bort; undertexter hör till titeln och rörs inte.
        scheduleDownloadPurge(profileID: id)
    }

    private static func profileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Profile") : String(trimmed.prefix(40))
    }

    // MARK: - Metadata i bakgrunden

    /// Högsta antal berikningsomgångar (à 200 titlar) per spellista och körning.
    nonisolated static let maxEnrichBatches = 1000
    /// Upptäcktens cache töms efter så här många omgångar (och när spellistan är klar), så att Hem-raderna
    /// följer med under en lång berikning utan att byggas om efter varje omgång.
    nonisolated static let invalidateEveryBatches = 5

    /// Köar berikning för spellistorna. En enda bakgrundsuppgift (lägsta prioritet) uppdaterar först listorna
    /// och berikar sedan spellistorna en i taget; pågår den redan läggs spellistorna bara till i kön.
    /// En spellista berikas tills en omgång inte har något att göra, inte kommer framåt eller avbryts (en omgång
    /// utan TMDB-träffar räknas som framsteg). Upptäcktens cache töms var femte omgång och efter varje
    /// spellista. Utan TMDB-nyckel görs ingenting.
    func scheduleMetadata(_ ids: [UUID]) {
        guard metadataConfigured else { return }
        for id in ids where !metadataQueue.contains(id) { metadataQueue.append(id) }
        guard metadataTask == nil, !metadataQueue.isEmpty else { return }
        let service = metadata, discovery = discovery, maxBatches = Self.maxEnrichBatches
        let invalidateEvery = Self.invalidateEveryBatches
        let run = UUID()
        metadataRun = run
        // En avbruten körning kan fortfarande vara på väg ut; den nya börjar först när den är klar.
        let previous = cancelledMetadataTask
        cancelledMetadataTask = nil
        metadataTask = Task.detached(priority: .background) { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await service.refreshLists()
            while !Task.isCancelled, let id = await self?.nextMetadataPlaylist(run: run) {
                var batches = 0
                while !Task.isCancelled, batches < maxBatches {
                    batches += 1
                    let outcome = await service.enrichBatch(playlistID: id)
                    if batches % invalidateEvery == 0 {
                        discovery.invalidate(playlistID: id)
                        await self?.invalidateMetadataCaches(playlistID: id)
                    }
                    // Inget kvar, inga framsteg, eller tillfälligt fel/anropsgräns: resten tas nästa körning.
                    if !outcome.shouldContinue { break }
                }
                discovery.invalidate(playlistID: id)
                await self?.invalidateMetadataCaches(playlistID: id)
                await self?.refreshMetadataStatus()
            }
        }
    }

    /// Avbryter bakgrundsberikningen. Med `keepQueue` behålls kön (anroparen schemalägger om den). Nästa
    /// körning väntar in den avbrutna, så att två körningar aldrig överlappar.
    func cancelBackgroundMetadata(keepQueue: Bool = false) {
        if let running = metadataTask {
            running.cancel()
            cancelledMetadataTask = running
        }
        metadataTask = nil
        metadataRun = UUID()
        metadataCurrent = nil
        if !keepQueue { metadataQueue = [] }
    }

    /// Spellistan tas bort: ta den ur kön och avbryt en pågående berikning av den; övriga köade spellistor
    /// fortsätter i en ny körning.
    private func stopMetadata(for id: UUID) {
        metadataQueue.removeAll { $0 == id }
        guard metadataCurrent == id else { return }
        cancelBackgroundMetadata(keepQueue: true)
        scheduleMetadata([])
    }

    /// Nästa spellista i kön. Är kön tom avslutas uppgiften här (i samma aktörstur), så att en ny
    /// schemaläggning alltid startar en ny uppgift.
    private func nextMetadataPlaylist(run: UUID) -> UUID? {
        guard run == metadataRun else { return nil }
        guard !metadataQueue.isEmpty else {
            metadataTask = nil
            metadataCurrent = nil
            return nil
        }
        let id = metadataQueue.removeFirst()
        metadataCurrent = id
        return id
    }

    /// Räknar matchade titlar och läser om TMDB godtagit nyckeln (för inställningarna).
    func refreshMetadataStatus() async {
        guard metadataConfigured else {
            matchedTitles = nil
            return
        }
        metadataAccepted = await metadata.isEnabled
        let metadataStore = metadataStore, ids = playlists.map(\.id)
        let count = try? await offMain(priority: .utility) { () throws -> Int in
            var total = 0
            for id in ids { total += try metadataStore.matchedCount(playlistID: id) }
            return total
        }
        if let count { matchedTitles = count }
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
    /// Titeln får inte visas för den aktiva (barn)profilen.
    case notAllowed
}

/// Var nästa-avsnitt-leverantören befinner sig.
@MainActor
private final class EpisodeCursor {
    var providerID: String
    init(providerID: String) { self.providerID = providerID }
}

/// PIN-spärren per profil (felaktiga försök i rad och spärrtid) i UserDefaults, som JSON under en nyckel.
struct PinLockoutStore {
    struct Entry: Codable, Equatable {
        var failures: Int
        var lockedUntil: Date?
    }

    static let key = "profiles.pinLockout.v1"
    let defaults: UserDefaults

    func entry(_ id: UUID) -> Entry? { all()[id.uuidString] }

    func set(_ entry: Entry?, for id: UUID) {
        var map = all()
        guard map[id.uuidString] != entry else { return }
        map[id.uuidString] = entry
        if map.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func all() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }
}
