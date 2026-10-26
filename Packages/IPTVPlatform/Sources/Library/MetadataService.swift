import Core
import Foundation
import Metadata
import Providers

/// Hämtar och cachar TMDB-metadata: lat hämtning per titel, bakgrundsberikning av katalogen och listor
/// (trendande/populärt). Kastar aldrig till anroparen; fel ger gammal cache eller `nil`.
public actor MetadataService {
    /// Titelmetadata räknas som färsk så här länge.
    public static let metadataTTL: TimeInterval = 30 * 24 * 3600
    /// Listor räknas som färska så här länge.
    public static let listTTL: TimeInterval = 12 * 3600
    /// Högst så här många samtidiga TMDB-anrop under berikning.
    public static let maxConcurrent = 4
    /// Antal nya försök per post efter `rateLimited` innan posten ges upp (i 7 dagar).
    public static let maxRateLimitRetries = 3
    /// Paus när TMDB inte anger `Retry-After`.
    public static let defaultRetryAfter: Double = 5

    public static let listNames = ["trending.movie", "trending.series", "popular.movie.SE", "popular.series.SE"]

    private let store: MetadataStore
    private let library: LibraryStore
    private let client: TMDBClient?
    private let omdb: OMDbClient?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void

    /// `false` när ingen klient finns eller när TMDB nekat token under sessionen.
    public private(set) var isEnabled: Bool

    public init(store: MetadataStore, library: LibraryStore, client: TMDBClient?, omdb: OMDbClient? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.library = library
        self.client = client
        self.omdb = omdb
        self.now = now
        self.sleep = sleep
        self.isEnabled = client != nil
    }

    // MARK: - Lat hämtning

    /// Metadata för en post: färsk cache direkt, annars matchning/hämtning. Vid fel returneras gammal cache.
    public func metadata(playlistID: UUID, kind: ContentKind, providerID: String) async -> TitleMetadata? {
        guard kind != .live else { return nil }
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
                let result = try await Self.resolveMatch(item, client: client, call: Caller())
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
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.metadataTTL { return cached.metadata }
        guard isEnabled, let client else { return cached?.metadata }
        do {
            let fresh = try await Self.fetchDetails(id: tmdbID, kind: kind, client: client, omdb: omdb, call: Caller())
            try? store.saveMetadata(fresh, now: now())
            return fresh
        } catch {
            handle(error)
            return cached?.metadata
        }
    }

    // MARK: - Berikning

    /// Matchar omatchade filmer och serier (högst `batch` st) mot TMDB med högst 4 samtidiga anrop och hämtar
    /// deras metadata. Returnerar antalet nya matchningar (poster som fick ett TMDB-id).
    public func enrich(playlistID: UUID, batch: Int = 200) async -> Int {
        guard isEnabled, let client, batch > 0 else { return 0 }
        let at = now()
        var work: [WorkItem] = []
        for kind in [ContentKind.movie, .series] where work.count < batch {
            let rows = (try? store.unmatchedItems(playlistID: playlistID, kind: kind, limit: batch - work.count, now: at)) ?? []
            work += rows.map { WorkItem(kind: kind, providerID: $0.providerID, title: $0.title, year: $0.year,
                                        providerTMDBID: $0.providerTMDBID) }
        }
        guard !work.isEmpty else { return 0 }

        let context = WorkerContext(client: client, omdb: omdb, store: store, gate: RateGate(sleep: sleep),
                                    now: now)
        var matched = 0
        var pending = work[...]
        await withTaskGroup(of: WorkerResult.self) { group in
            func addNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask { await Self.process(item, context: context) }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            while let result = await group.next() {
                switch result {
                case let .done(item, tmdbID, confidence, metadata):
                    // En transaktion per resultat (matchning + metadata + genrer).
                    do {
                        try store.saveEnrichment(playlistID: playlistID, kind: item.kind, providerID: item.providerID,
                                                 tmdbID: tmdbID, confidence: confidence, metadata: metadata, now: now())
                        if tmdbID != nil { matched += 1 }
                    } catch {}
                case .transientFailure:
                    break   // Inget sparas: posten försöks igen vid nästa berikning.
                case .unauthorized:
                    isEnabled = false
                    group.cancelAll()
                    pending = []
                case .cancelled:
                    pending = []
                }
                if Task.isCancelled { pending = [] }
                addNext()
            }
        }
        return matched
    }

    // MARK: - Listor

    /// Hämtar trendande och populära titlar (TTL 12 h). Färska listor hoppas över.
    public func refreshLists() async {
        guard isEnabled, let client else { return }
        let jobs: [(String, @Sendable () async throws -> [Int])] = [
            ("trending.movie", { try await client.trending(kind: .movie) }),
            ("trending.series", { try await client.trending(kind: .series) }),
            ("popular.movie.SE", { try await client.popular(kind: .movie, region: "SE") }),
            ("popular.series.SE", { try await client.popular(kind: .series, region: "SE") }),
        ]
        for (name, fetch) in jobs {
            guard isEnabled, !Task.isCancelled else { return }
            if let existing = try? store.list(name), now().timeIntervalSince(existing.fetchedAt) < Self.listTTL { continue }
            do {
                let ids = try await fetch()
                try? store.saveList(name, ids: ids, now: now())
            } catch TMDBError.rateLimited {
                return   // Nästa uppdatering försöker igen.
            } catch {
                handle(error)
            }
        }
    }

    // MARK: - Internt

    private func handle(_ error: any Error) {
        if case TMDBError.unauthorized = error { isEnabled = false }
    }

    private func catalogItem(playlistID: UUID, kind: ContentKind, providerID: String) -> WorkItem? {
        switch kind {
        case .movie:
            guard let m = try? library.movie(playlistID: playlistID, providerID: providerID) else { return nil }
            return WorkItem(kind: kind, providerID: providerID, title: m.title, year: m.year, providerTMDBID: m.tmdbID)
        case .series:
            guard let s = try? library.series(playlistID: playlistID, providerID: providerID) else { return nil }
            return WorkItem(kind: kind, providerID: providerID, title: s.title, year: s.year, providerTMDBID: s.tmdbID)
        case .live:
            return nil
        }
    }

    struct WorkItem: Sendable {
        let kind: ContentKind
        let providerID: String
        let title: String
        let year: Int?
        let providerTMDBID: Int?
    }

    enum WorkerResult: Sendable {
        case done(WorkItem, tmdbID: Int?, confidence: Double, metadata: TitleMetadata?)
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
               context.now().timeIntervalSince(cached.fetchedAt) < metadataTTL {
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: nil)
            }
            do {
                let metadata = try await fetchDetails(id: id, kind: item.kind, client: context.client,
                                                      omdb: context.omdb, call: call)
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: metadata)
            } catch TMDBError.notFound {
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: nil)
            } catch TMDBError.unauthorized {
                return .unauthorized
            } catch is CancellationError {
                return .cancelled
            } catch {
                // Matchningen sparas ändå; metadatan hämtas lat vid behov.
                return .done(item, tmdbID: id, confidence: match.confidence, metadata: nil)
            }
        } catch is RateLimitExhausted {
            // Ges upp: registreras som försök utan id så att posten vilar i 7 dagar.
            return .done(item, tmdbID: nil, confidence: 0, metadata: nil)
        } catch TMDBError.unauthorized {
            return .unauthorized
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transientFailure
        }
    }

    /// Leverantörens `tmdbID` kortsluter sökningen. Annars: städad titel (+ leverantörens år), sök med år om det
    /// är känt och, om ingen träff hittas, en gång till utan år.
    private static func resolveMatch(_ item: WorkItem, client: TMDBClient, call: Caller) async throws -> MatchResult {
        if let id = item.providerTMDBID { return MatchResult(tmdbID: id, confidence: 1) }
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

/// Kör TMDB-anrop. Med grind väntar varje anrop ut en pågående paus, och `rateLimited` pausar alla arbetare och
/// försöker igen (inom postens budget). Utan grind (lat hämtning) körs anropet direkt.
struct Caller: Sendable {
    var gate: RateGate?
    var retries: RetryBudget?

    func callAsFunction<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        guard let gate, let retries else { return try await op() }
        while true {
            await gate.wait()
            try Task.checkCancellation()
            do {
                return try await op()
            } catch let TMDBError.rateLimited(retryAfter) {
                guard await retries.consume() else { throw RateLimitExhausted() }
                await gate.pause(seconds: retryAfter ?? MetadataService.defaultRetryAfter)
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

/// Gemensam paus för alla arbetare: när ett anrop får `rateLimited` väntar alla in pausen innan nästa anrop.
actor RateGate {
    private let sleep: @Sendable (Duration) async -> Void
    private var current: Task<Void, Never>?

    init(sleep: @escaping @Sendable (Duration) async -> Void) {
        self.sleep = sleep
    }

    func wait() async {
        if let current { await current.value }
    }

    /// Startar en paus om ingen pågår (annars väntas den pågående in) och väntar tills den är slut.
    func pause(seconds: Double) async {
        if let current {
            await current.value
            return
        }
        let sleep = self.sleep
        let task = Task { await sleep(.seconds(max(0, seconds))) }
        current = task
        await task.value
        if current == task { current = nil }
    }
}
