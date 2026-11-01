import Core
import Foundation
import Metadata
import Providers

/// Hämtar och cachar TMDB-metadata: lat hämtning per titel, bakgrundsberikning av katalogen och listor
/// (trendande/populärt). Kastar aldrig till anroparen; fel ger gammal cache eller `nil`.
///
/// Alla vägar delar en `RateGate`: efter `rateLimited` gör lat hämtning och listuppdatering inga anrop förrän
/// pausen är slut (de returnerar cache eller `nil`), medan berikningens arbetare väntar ut den.
public actor MetadataService {
    /// Titelmetadata räknas som färsk så här länge (och bara om den hämtats på klientens språk).
    public static let metadataTTL: TimeInterval = 30 * 24 * 3600
    /// Listor räknas som färska så här länge.
    public static let listTTL: TimeInterval = 12 * 3600
    /// Högst så här många samtidiga TMDB-anrop under berikning.
    public static let maxConcurrent = 4
    /// Antal nya försök per post efter `rateLimited` innan posten ges upp (i 7 dagar).
    public static let maxRateLimitRetries = 3
    /// Paus när TMDB inte anger `Retry-After`.
    public static let defaultRetryAfter: Double = 5
    /// Längsta paus som respekteras, oavsett `Retry-After`.
    public static let maxRetryAfter: Double = 60

    public static let listNames = ["trending.movie", "trending.series", "popular.movie.SE", "popular.series.SE"]

    private let store: MetadataStore
    private let library: LibraryStore
    private let client: TMDBClient?
    private let omdb: OMDbClient?
    private let now: @Sendable () -> Date
    private let gate: RateGate

    /// Pågående arbete, så att samtidiga anrop delar på samma förfrågningar.
    private var enrichTasks: [UUID: Task<EnrichOutcome, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var metadataTasks: [String: Task<TitleMetadata?, Never>] = [:]
    /// Hämtade säsonger (TMDB-id och säsong), för sessionen.
    private var episodeCache: [String: [Int: TMDBEpisodeInfo]] = [:]

    /// `false` när ingen klient finns eller när TMDB nekat token under sessionen.
    public private(set) var isEnabled: Bool

    /// `sleep` används för pauser efter `rateLimited` och ska returnera direkt när uppgiften avbryts.
    public init(store: MetadataStore, library: LibraryStore, client: TMDBClient?, omdb: OMDbClient? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.library = library
        self.client = client
        self.omdb = omdb
        self.now = now
        self.gate = RateGate(now: now, sleep: sleep)
        self.isEnabled = client != nil
    }

    // MARK: - Lat hämtning

    /// Metadata för en post: färsk cache direkt, annars matchning/hämtning. Vid fel, eller medan TMDB
    /// begränsar anropen, returneras gammal cache (eller `nil`). Samtidiga anrop för samma post delar förfrågan.
    public func metadata(playlistID: UUID, kind: ContentKind, providerID: String) async -> TitleMetadata? {
        guard kind != .live else { return nil }
        let key = "\(playlistID.uuidString)|\(kind.rawValue)|\(providerID)"
        if let running = metadataTasks[key] { return await running.value }
        let task = Task { await self.loadMetadata(playlistID: playlistID, kind: kind, providerID: providerID) }
        metadataTasks[key] = task
        let value = await task.value
        metadataTasks[key] = nil
        return value
    }

    private func loadMetadata(playlistID: UUID, kind: ContentKind, providerID: String) async -> TitleMetadata? {
        let call = Caller(gate: gate, retries: nil)
        var tmdbID = try? store.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID)
        if tmdbID == nil {
            guard isEnabled, let client, let item = catalogItem(playlistID: playlistID, kind: kind, providerID: providerID)
            else { return nil }
            // Ett nyligt misslyckat försök görs inte om (samma regel som berikningen).
            if let attempt = try? store.match(playlistID: playlistID, kind: kind, providerID: providerID),
               now().timeIntervalSince(attempt.attemptedAt) < MetadataStore.unmatchedRetryInterval {
                return nil
            }
            do {
                let result = try await Self.resolveMatch(item, client: client, call: call)
                try? store.saveMatch(playlistID: playlistID, kind: kind, providerID: providerID, tmdbID: result.tmdbID,
                                     confidence: result.confidence, now: now())
                tmdbID = result.tmdbID
            } catch {
                handle(error)
                return nil
            }
        }
        guard let tmdbID else { return nil }

        let cached = try? store.cachedMetadata(kind: kind, tmdbID: tmdbID)
        if let cached, Self.isFresh(cached, now: now(), language: client?.language) { return cached.metadata }
        guard isEnabled, let client else { return cached?.metadata }
        do {
            let fresh = try await Self.fetchDetails(id: tmdbID, kind: kind, client: client, omdb: omdb, call: call)
            try? store.saveMetadata(fresh, now: now())
            return fresh
        } catch {
            handle(error)
            return cached?.metadata
        }
    }

    // MARK: - Avsnitt

    /// Avsnitten i en säsong ur TMDB (titel, beskrivning, speltid, stillbild) per avsnittsnummer. Leverantörens avsnitt
    /// heter ofta bara "Serie S01E02"; här finns de riktiga titlarna. Serien matchas först om det behövs. Resultatet
    /// minns sessionen ut (bara hämtade, icke-tomma säsonger). Tomt vid fel, utan nyckel, när serien inte matchats och
    /// medan TMDB begränsar anropen; då används leverantörens uppgifter.
    public func episodes(playlistID: UUID, providerID: String, season: Int) async -> [Int: TMDBEpisodeInfo] {
        var tmdbID = try? store.tmdbID(playlistID: playlistID, kind: .series, providerID: providerID)
        if tmdbID == nil {
            _ = await metadata(playlistID: playlistID, kind: .series, providerID: providerID)
            tmdbID = try? store.tmdbID(playlistID: playlistID, kind: .series, providerID: providerID)
        }
        guard let id = tmdbID else { return [:] }
        let key = "\(id)|\(season)"
        if let cached = episodeCache[key] { return cached }
        guard isEnabled, let client else { return [:] }
        let call = Caller(gate: gate, retries: nil)
        do {
            let found = try await call { try await client.seasonEpisodes(seriesID: id, season: season) }
            if !found.isEmpty { episodeCache[key] = found }
            return found
        } catch {
            handle(error)
            return [:]
        }
    }

    // MARK: - Berikning

    /// Matchar omatchade filmer och serier (högst `batch` st) mot TMDB med högst 4 samtidiga anrop och hämtar
    /// deras metadata; matchade poster som saknar metadata kompletteras också. Returnerar antalet nya
    /// matchningar (poster som fick ett TMDB-id). Ett andra anrop för samma spellista medan ett pågår väntar
    /// in det pågående och returnerar dess värde.
    public func enrich(playlistID: UUID, batch: Int = 200) async -> Int {
        await enrichBatch(playlistID: playlistID, batch: batch).matched
    }

    /// Som `enrich`, men med hela utfallet: hur många poster omgången arbetade med, hur många som kom framåt
    /// och om den avbröts (tillfälligt fel, anropsgräns, nekad nyckel eller avbrott). En omgång utan en enda
    /// TMDB-träff kan alltså ha gjort framsteg (försöken sparas), så nästa omgång kan ha nya poster att matcha.
    public func enrichBatch(playlistID: UUID, batch: Int = 200) async -> EnrichOutcome {
        if let running = enrichTasks[playlistID] { return await running.value }
        let task = Task { await self.runEnrich(playlistID: playlistID, batch: batch) }
        enrichTasks[playlistID] = task
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        enrichTasks[playlistID] = nil
        return value
    }

    private func runEnrich(playlistID: UUID, batch: Int) async -> EnrichOutcome {
        guard isEnabled, let client, batch > 0 else { return EnrichOutcome() }
        let at = now()
        var work: [WorkItem] = []
        for kind in [ContentKind.movie, .series] where work.count < batch {
            let rows = (try? store.unmatchedItems(playlistID: playlistID, kind: kind, limit: batch - work.count, now: at)) ?? []
            work += rows.map { WorkItem(kind: kind, providerID: $0.providerID, title: $0.title, year: $0.year,
                                        knownTMDBID: $0.providerTMDBID) }
        }
        // Matchade men utan metadata (t.ex. tidigare misslyckad detaljhämtning): räknas inte som nya matchningar.
        for kind in [ContentKind.movie, .series] where work.count < batch {
            let rows = (try? store.matchedWithoutMetadata(playlistID: playlistID, kind: kind, limit: batch - work.count)) ?? []
            work += rows.map { WorkItem(kind: kind, providerID: $0.providerID, title: $0.title, year: nil,
                                        knownTMDBID: $0.tmdbID, knownConfidence: $0.confidence, isSweep: true) }
        }
        guard !work.isEmpty else { return EnrichOutcome() }

        let context = WorkerContext(client: client, omdb: omdb, store: store, gate: gate, now: now)
        var outcome = EnrichOutcome(workItems: work.count)
        var pending = work[...]
        await withTaskGroup(of: WorkerResult.self) { group in
            func addNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask { await Self.process(item, context: context) }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            while let result = await group.next() {
                switch result {
                case let .done(item, tmdbID, confidence, metadata, gaveUp):
                    // En transaktion per resultat (matchning + metadata + genrer).
                    do {
                        try store.saveEnrichment(playlistID: playlistID, kind: item.kind, providerID: item.providerID,
                                                 tmdbID: tmdbID, confidence: confidence, metadata: metadata, now: now())
                        if tmdbID != nil, !item.isSweep { outcome.matched += 1 }
                        // En ny post får alltid ett sparat försök; en komplettering bara om metadatan kom.
                        if !item.isSweep || metadata != nil { outcome.progressed += 1 }
                    } catch {}
                    if gaveUp { outcome.interrupted = true }
                case .transientFailure:
                    outcome.interrupted = true   // Inget sparas: posten försöks igen vid nästa berikning.
                case .unauthorized:
                    outcome.interrupted = true
                    isEnabled = false
                    pending = []
                    group.cancelAll()   // Väntande arbetare avbryts direkt, även mitt i en paus.
                case .cancelled:
                    outcome.interrupted = true
                    pending = []
                }
                if Task.isCancelled { pending = [] }
                addNext()
            }
        }
        if Task.isCancelled { outcome.interrupted = true }
        return outcome
    }

    // MARK: - Listor

    /// Hämtar trendande och populära titlar (TTL 12 h). Färska listor hoppas över, och under en paus efter
    /// `rateLimited` görs inga anrop. Samtidiga anrop delar på samma uppdatering.
    public func refreshLists() async {
        if let running = refreshTask { return await running.value }
        let task = Task { await self.runRefreshLists() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func runRefreshLists() async {
        guard isEnabled, let client else { return }
        let jobs: [(String, @Sendable () async throws -> [Int])] = [
            ("trending.movie", { try await client.trending(kind: .movie) }),
            ("trending.series", { try await client.trending(kind: .series) }),
            ("popular.movie.SE", { try await client.popular(kind: .movie, region: "SE") }),
            ("popular.series.SE", { try await client.popular(kind: .series, region: "SE") }),
        ]
        let call = Caller(gate: gate, retries: nil)
        for (name, fetch) in jobs {
            guard isEnabled, !Task.isCancelled else { return }
            if let existing = try? store.list(name), now().timeIntervalSince(existing.fetchedAt) < Self.listTTL { continue }
            do {
                let ids = try await call { try await fetch() }
                try? store.saveList(name, ids: ids, now: now())
            } catch TMDBError.rateLimited {
                return   // Pausen gäller; nästa uppdatering försöker igen.
            } catch {
                handle(error)
            }
        }
    }

    // MARK: - Internt

    private func handle(_ error: any Error) {
        if case TMDBError.unauthorized = error { isEnabled = false }
    }

    /// Färsk = inom TTL och (med klient) hämtad på klientens språk.
    static func isFresh(_ cached: (metadata: TitleMetadata, fetchedAt: Date), now: Date, language: String?) -> Bool {
        guard now.timeIntervalSince(cached.fetchedAt) < metadataTTL else { return false }
        return language.map { cached.metadata.language == $0 } ?? true
    }

    private func catalogItem(playlistID: UUID, kind: ContentKind, providerID: String) -> WorkItem? {
        switch kind {
        case .movie:
            guard let m = try? library.movie(playlistID: playlistID, providerID: providerID) else { return nil }
            return WorkItem(kind: kind, providerID: providerID, title: m.title, year: m.year, knownTMDBID: m.tmdbID)
        case .series:
            guard let s = try? library.series(playlistID: playlistID, providerID: providerID) else { return nil }
            return WorkItem(kind: kind, providerID: providerID, title: s.title, year: s.year, knownTMDBID: s.tmdbID)
        case .live:
            return nil
        }
    }

    struct WorkItem: Sendable {
        let kind: ContentKind
        let providerID: String
        let title: String
        let year: Int?
        /// Leverantörens id, eller (vid komplettering) det redan matchade id:t. Kortsluter sökningen.
        let knownTMDBID: Int?
        var knownConfidence: Double = 1
        /// Komplettering av en redan matchad post.
        var isSweep = false
    }

    enum WorkerResult: Sendable {
        /// `gaveUp`: anropsgränsen tog slut och posten registrerades som försök utan id.
        case done(WorkItem, tmdbID: Int?, confidence: Double, metadata: TitleMetadata?, gaveUp: Bool = false)
        case transientFailure
        case unauthorized
        case cancelled
    }

    struct WorkerContext: Sendable {
        let client: TMDBClient
        let omdb: OMDbClient?
        let store: MetadataStore
        let gate: RateGate
        let now: @Sendable () -> Date
    }

    /// Matchar en post och hämtar metadata (om cachen inte är färsk). Körs i en barnuppgift, utanför aktören.
    private static func process(_ item: WorkItem, context: WorkerContext) async -> WorkerResult {
        let call = Caller(gate: context.gate, retries: RetryBudget())
        do {
            let match = try await resolveMatch(item, client: context.client, call: call)
            guard let id = match.tmdbID else {
                return .done(item, tmdbID: nil, confidence: match.confidence, metadata: nil)
            }
            if let cached = try? context.store.cachedMetadata(kind: item.kind, tmdbID: id),
               isFresh(cached, now: context.now(), language: context.client.language) {
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: nil)
            }
            do {
                let metadata = try await fetchDetails(id: id, kind: item.kind, client: context.client,
                                                      omdb: context.omdb, call: call)
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: metadata)
            } catch TMDBError.notFound {
                // Id:t finns inte hos TMDB: registreras som försök utan id (vilar i 7 dagar).
                return .done(item, tmdbID: nil, confidence: 0, metadata: nil)
            } catch TMDBError.unauthorized {
                return .unauthorized
            } catch is CancellationError {
                return .cancelled
            } catch {
                // Matchningen sparas ändå; metadatan kompletteras vid nästa berikning eller hämtas lat.
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: nil)
            }
        } catch is RateLimitExhausted {
            // Ges upp: registreras som försök utan id så att posten vilar i 7 dagar.
            return .done(item, tmdbID: nil, confidence: 0, metadata: nil, gaveUp: true)
        } catch TMDBError.unauthorized {
            return .unauthorized
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transientFailure
        }
    }

    /// Känt id kortsluter sökningen. Annars: städad titel (+ leverantörens år), sök med år om det är känt och,
    /// om ingen träff hittas, en gång till utan år.
    private static func resolveMatch(_ item: WorkItem, client: TMDBClient, call: Caller) async throws -> MatchResult {
        if let id = item.knownTMDBID { return MatchResult(tmdbID: id, confidence: item.knownConfidence) }
        let kind = item.kind
        let cleaned = TitleCleaner.clean(item.title)
        let title = CleanTitle(title: cleaned.title, year: item.year ?? cleaned.year)
        let candidates = try await call { try await client.search(title.title, year: title.year, kind: kind) }
        var result = TMDBMatcher.match(title, kind: kind, candidates: candidates)
        if result.tmdbID == nil, title.year != nil {
            let retry = try await call { try await client.search(title.title, year: nil, kind: kind) }
            let second = TMDBMatcher.match(title, kind: kind, candidates: retry)
            if second.tmdbID != nil || second.confidence > result.confidence { result = second }
        }
        return result
    }

    /// TMDB-detaljer, kompletterade med OMDb-betyg när det finns ett IMDb-id (OMDb-fel ignoreras).
    private static func fetchDetails(id: Int, kind: ContentKind, client: TMDBClient, omdb: OMDbClient?,
                                     call: Caller) async throws -> TitleMetadata {
        var metadata = try await call { try await client.details(id: id, kind: kind) }
        if let omdb, let imdbID = metadata.imdbID {
            do {
                let ratings = try await omdb.ratings(imdbID: imdbID)
                metadata.imdbRating = ratings.imdb
                metadata.rottenTomatoes = ratings.rottenTomatoes
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        return metadata
    }
}

private struct RateLimitExhausted: Error {}

/// Kör TMDB-anrop genom den gemensamma grinden.
/// - Med `retries` (berikning): väntar ut en pågående paus, och `rateLimited` pausar alla och försöker igen
///   inom postens budget.
/// - Utan `retries` (lat hämtning, listor): under en paus görs inget anrop (kastar `rateLimited`), och
///   `rateLimited` startar pausen och kastas vidare.
struct Caller: Sendable {
    let gate: RateGate
    let retries: RetryBudget?

    func callAsFunction<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        while true {
            if retries != nil {
                await gate.wait()
            } else if await gate.isPaused() {
                throw TMDBError.rateLimited(retryAfter: nil)
            }
            try Task.checkCancellation()
            do {
                return try await op()
            } catch let TMDBError.rateLimited(retryAfter) {
                await gate.pause(seconds: retryAfter ?? MetadataService.defaultRetryAfter)
                guard let retries else { throw TMDBError.rateLimited(retryAfter: retryAfter) }
                guard await retries.consume() else { throw RateLimitExhausted() }
            }
        }
    }
}

/// Antal återstående omförsök för en post efter `rateLimited`.
actor RetryBudget {
    private var remaining = MetadataService.maxRateLimitRetries
    func consume() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// Gemensam paus efter `rateLimited` (`Retry-After`, högst 60 s). Arbetare som väntar sover till pausens slut;
/// sömnen avbryts när uppgiften avbryts.
actor RateGate {
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private(set) var pausedUntil: Date?

    init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.now = now
        self.sleep = sleep
    }

    func isPaused() -> Bool {
        guard let pausedUntil else { return false }
        return now() < pausedUntil
    }

    /// Förlänger pausen till minst `seconds` (begränsat till 0…60 s) från nu.
    func pause(seconds: Double) {
        let clamped = min(max(seconds.isFinite ? seconds : MetadataService.defaultRetryAfter, 0),
                          MetadataService.maxRetryAfter)
        let until = now().addingTimeInterval(clamped)
        if let current = pausedUntil, current >= until { return }
        pausedUntil = until
    }

    /// Sover den återstående pausen (en gång) och återvänder direkt om ingen paus pågår eller om uppgiften
    /// avbryts.
    func wait() async {
        guard let pausedUntil, !Task.isCancelled else { return }
        let remaining = pausedUntil.timeIntervalSince(now())
        guard remaining > 0 else { return }
        await sleep(.seconds(remaining))
    }
}

/// Utfallet av en berikningsomgång (`MetadataService.enrichBatch`).
public struct EnrichOutcome: Sendable, Equatable {
    /// Poster som omgången tog sig an (0: inget kvar att göra just nu).
    public var workItems = 0
    /// Nya matchningar (poster som fick ett TMDB-id).
    public var matched = 0
    /// Poster vars läge ändrades (ett sparat försök, eller kompletterad metadata).
    public var progressed = 0
    /// Omgången avbröts eller stötte på tillfälliga fel eller anropsgränsen.
    public var interrupted = false

    public init(workItems: Int = 0, matched: Int = 0, progressed: Int = 0, interrupted: Bool = false) {
        self.workItems = workItems
        self.matched = matched
        self.progressed = progressed
        self.interrupted = interrupted
    }

    /// Lönar det sig att köra en omgång till direkt? Nej om inget fanns att göra, inget kom framåt eller
    /// omgången avbröts.
    public var shouldContinue: Bool { workItems > 0 && progressed > 0 && !interrupted }
}
