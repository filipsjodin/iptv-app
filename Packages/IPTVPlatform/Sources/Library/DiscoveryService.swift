import Core
import Discovery
import Foundation
import GRDB
import Metadata
import Personal
import PlaybackCore
import Synchronization

/// Upptäckt per spellista och profil: bygger `Candidate`s ur katalog, matchningar och cachad TMDB-metadata och
/// tar fram Hem-raderna, liknande titlar, titlar per person och sökning med barnfilter.
///
/// Kandidaterna cachas i minnet per (spellista, typ). Appen anropar `invalidate(playlistID:)` efter import och
/// berikning. För barnprofiler går allt som returneras genom `DiscoveryEngine.kidsFilter` (titlar utan känd
/// åldersgräns visas inte). Live och Sport ingår aldrig i utdata härifrån; för barnprofiler filtreras även
/// livekanaler bort ur sökningen.
public final class DiscoveryService: Sendable {
    /// Högsta antal titlar per rad (utom Topp 10).
    public static let rowLimit = 20
    /// Antal genrerader per typ.
    public static let genreRowCount = 8

    let library: LibraryStore
    let metadata: MetadataStore
    private let state = Mutex(CacheState())

    public init(library: LibraryStore, metadata: MetadataStore) {
        self.library = library
        self.metadata = metadata
    }

    // MARK: - Kandidater och cache

    /// Spellistans titlar av typen `kind` som kandidater, sorterade på popularitet (högst först, saknad sist,
    /// sedan typ och `providerID`). Live ger en tom lista.
    public func candidates(playlistID: UUID, kind: ContentKind) throws -> [Candidate] {
        try snapshot(playlistID: playlistID, kind: kind).candidates
    }

    /// Tömmer cachade kandidater (och genrenamn) för spellistan. Anropas efter import och berikning.
    public func invalidate(playlistID: UUID) {
        state.withLock { s in
            s.generation[playlistID, default: 0] += 1
            for kind in [ContentKind.movie, .series] { s.snapshots[CacheKey(playlistID: playlistID, kind: kind)] = nil }
            s.genreNames = [:]
        }
    }

    /// Genrens namn ur cachad metadata (språket som metadatan hämtades på), eller `nil` om ingen titel har genren.
    public func genreName(_ id: Int) -> String? {
        if let cached = state.withLock({ $0.genreNames[id] }) { return cached }
        let json: String? = try? library.db.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT json_extract(m.json, '$.genres') FROM titleGenre g
                JOIN tmdbTitle m ON m.kind = g.kind AND m.tmdbID = g.tmdbID
                WHERE g.genreID = ? LIMIT 1
                """, arguments: [id])
        }
        guard let json, let genres = try? JSONDecoder().decode([Genre].self, from: Data(json.utf8)),
              let name = genres.first(where: { $0.id == id })?.name else { return nil }
        state.withLock { $0.genreNames[id] = name }
        return name
    }

    // MARK: - Hem

    /// Hem-raderna för profilen i ordningen För dig, Topp 10 filmer, Topp 10 serier, Nyligen tillagt (per typ),
    /// Min lista och genrer (de `genreRowCount` största genrerna per typ, filmer före serier). Tomma rader
    /// utelämnas. Fortsätt titta kommer från appen. `kinds` avgör vilka typer som ingår (live ignoreras).
    public func rows(playlistID: UUID, profile: Profile, personal: any PersonalStore, userState: any UserStateStore,
                     kinds: [ContentKind]) throws -> [(RowID, [LibraryItem])] {
        var order: [ContentKind] = []
        for k in kinds where k != .live && !order.contains(k) { order.append(k) }
        var snaps: [ContentKind: Snapshot] = [:]
        for k in order { snaps[k] = try snapshot(playlistID: playlistID, kind: k) }
        let kids = profile.isKids
        func pool(_ k: ContentKind) -> [Candidate] {
            let all = snaps[k]?.candidates ?? []
            return kids ? DiscoveryEngine.kidsFilter(all) : all
        }
        let pools = Dictionary(uniqueKeysWithValues: order.map { ($0, pool($0)) })
        func items(_ refs: [ItemRef]) -> [LibraryItem] { refs.compactMap { Self.item($0, snaps) } }

        var rows: [(RowID, [LibraryItem])] = []
        func add(_ id: RowID, _ list: [LibraryItem]) { if !list.isEmpty { rows.append((id, list)) } }

        let signals = try signals(playlistID: playlistID, personal: personal, userState: userState, snaps: snaps)
        add(.forYou, items(DiscoveryEngine.forYou(candidates: order.flatMap { pools[$0] ?? [] }, signals: signals,
                                                 limit: Self.rowLimit)))

        for k in [ContentKind.movie, .series] where order.contains(k) {
            let ranked = try rankedTMDBIDs(kind: k)
            add(.topTen(k), items(DiscoveryEngine.topTen(rankedTMDBIDs: ranked, candidates: pools[k] ?? [])))
        }

        for k in order {
            let added = snaps[k]?.byAdded ?? []
            let dated = kids ? DiscoveryEngine.kidsFilter(added) : added
            add(.recentlyAdded(k), items(DiscoveryEngine.recentlyAdded(candidates: dated, limit: Self.rowLimit)))
        }

        let myList = personal.myList().filter { ref in
            guard order.contains(ref.kind), let info = snaps[ref.kind]?.info[ref.providerID] else { return false }
            return !kids || Self.kidsAllowed(info.ageLimit)
        }
        add(.myList, items(myList))

        for k in order {
            let p = pools[k] ?? []
            for g in Self.largestGenres(p, count: Self.genreRowCount) {
                add(.genre(g, k), items(DiscoveryEngine.byGenre(g, candidates: p, limit: Self.rowLimit)))
            }
        }
        return rows
    }

    // MARK: - Liknande, per person och sökning

    /// Liknande titlar av samma typ: TMDB:s `similar` först, därefter genre- och nyckelordsöverlapp.
    /// `kids` tillämpar barnfiltret på resultatet.
    public func similar(playlistID: UUID, kind: ContentKind, providerID: String, limit: Int,
                        kids: Bool = false) throws -> [LibraryItem] {
        let snap = try snapshot(playlistID: playlistID, kind: kind)
        guard let info = snap.info[providerID] else { return [] }
        let target = snap.candidates[info.index]
        var tmdbSimilar: [Int] = []
        if let id = target.tmdbID {
            tmdbSimilar = try intLists(kind: kind, tmdbIDs: [id], path: "$.similar")[id] ?? []
        }
        let pool = kids ? DiscoveryEngine.kidsFilter(snap.candidates) : snap.candidates
        let refs = DiscoveryEngine.similar(to: target, candidates: pool, tmdbSimilar: tmdbSimilar, limit: limit)
        let snaps = [kind: snap]
        return refs.compactMap { Self.item($0, snaps) }
    }

    /// Filmer och serier där personen medverkar (skådespelare, regissör eller serieskapare), populärast först.
    public func byPerson(playlistID: UUID, personID: Int, kids: Bool = false) throws -> [LibraryItem] {
        var snaps: [ContentKind: Snapshot] = [:]
        var all: [Candidate] = []
        for k in [ContentKind.movie, .series] {
            let s = try snapshot(playlistID: playlistID, kind: k)
            snaps[k] = s
            all += kids ? DiscoveryEngine.kidsFilter(s.candidates) : s.candidates
        }
        return DiscoveryEngine.byPerson(personID, candidates: all).compactMap { Self.item($0, snaps) }
    }

    /// `LibraryStore.search` med barnfilter: för barnprofiler visas bara filmer och serier vars åldersgräns
    /// klarar `kidsFilter` (livekanaler utesluts). Barnsökningen hämtar fler träffar än `limit` innan filtret,
    /// men kan ändå ge färre än `limit` om de flesta träffar filtreras bort.
    public func search(_ query: String, playlistID: UUID, kind: ContentKind? = nil, limit: Int,
                       kids: Bool = false) throws -> [LibraryItem] {
        guard kids else { return try library.search(query, playlistID: playlistID, kind: kind, limit: limit) }
        guard kind != .live, limit > 0 else { return [] }
        let hits = try library.search(query, playlistID: playlistID, kind: kind, limit: limit * 4)
        var snaps: [ContentKind: Snapshot] = [:]
        var out: [LibraryItem] = []
        for hit in hits where hit.kind != .live {
            if snaps[hit.kind] == nil { snaps[hit.kind] = try snapshot(playlistID: playlistID, kind: hit.kind) }
            guard let info = snaps[hit.kind]?.info[hit.providerID], Self.kidsAllowed(info.ageLimit) else { continue }
            out.append(hit)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: - Signaler

    /// Profilens signaler. Avsnitt räknas till serien (`ItemRef(kind: .series, providerID: seriesProviderID)`)
    /// med högsta andel sett över avsnitten. `recommendationsFor` fylls för titlar med positiv vikt.
    func signals(playlistID: UUID, personal: any PersonalStore, userState: any UserStateStore,
                 snaps: [ContentKind: Snapshot]) throws -> Signals {
        var watched: [ItemRef: Double] = [:]
        for p in userState.entries(playlistID: playlistID) where p.key.kind != .live {
            let ref = p.key.seriesProviderID.map { ItemRef(kind: .series, providerID: $0) }
                ?? ItemRef(kind: p.key.kind, providerID: p.key.providerID)
            let fraction: Double
            if p.watched {
                fraction = 1
            } else if let d = p.duration, d > 0 {
                fraction = min(1, max(0, p.position / d))
            } else {
                fraction = 0
            }
            watched[ref] = max(watched[ref] ?? 0, fraction)
        }
        let ratings = personal.ratings()
        let myList = Set(personal.myList())

        // Samma vikter som DiscoveryEngine.forYou (👍, Min lista, sedd ≥ 0,9; 👎 drar ner).
        var weights: [ItemRef: Double] = [:]
        for (r, f) in watched where f >= ProgressPolicy.watchedFraction { weights[r, default: 0] += 1 }
        for (r, rating) in ratings { weights[r, default: 0] += rating == .up ? 2 : -3 }
        for r in myList { weights[r, default: 0] += 1 }
        var positive: [ContentKind: [ItemRef: Int]] = [:]
        for (r, w) in weights where w > 0 {
            if let id = snaps[r.kind]?.info[r.providerID]?.tmdbID { positive[r.kind, default: [:]][r] = id }
        }
        var recommendations: [ItemRef: [Int]] = [:]
        for (kind, refs) in positive {
            let lists = try intLists(kind: kind, tmdbIDs: Array(Set(refs.values)), path: "$.recommendations")
            for (r, id) in refs { if let l = lists[id], !l.isEmpty { recommendations[r] = l } }
        }
        return Signals(watched: watched, ratings: ratings, myList: myList, recommendationsFor: recommendations)
    }

    // MARK: - Intern

    struct Info: Sendable {
        var index: Int
        var title: String
        var year: Int?
        var poster: String?
        var tmdbID: Int?
        var ageLimit: Int?
    }

    struct Snapshot: Sendable {
        /// Sorterade på popularitet (samma ordning som motorns tie-break, så motorns sortering blir linjär).
        var candidates: [Candidate] = []
        /// Titlar med `addedAt`, nyast först.
        var byAdded: [Candidate] = []
        var info: [String: Info] = [:]
    }

    private struct CacheKey: Hashable {
        var playlistID: UUID
        var kind: ContentKind
    }

    private struct CacheState {
        var snapshots: [CacheKey: Snapshot] = [:]
        var generation: [UUID: Int] = [:]
        var genreNames: [Int: String] = [:]
    }

    func snapshot(playlistID: UUID, kind: ContentKind) throws -> Snapshot {
        guard kind != .live else { return Snapshot() }
        let key = CacheKey(playlistID: playlistID, kind: kind)
        let (cached, generation) = state.withLock { ($0.snapshots[key], $0.generation[playlistID] ?? 0) }
        if let cached { return cached }
        let built = try build(playlistID: playlistID, kind: kind)
        // Lagras bara om ingen invalidering skett under bygget (annars kan datan vara inaktuell).
        state.withLock { s in
            if (s.generation[playlistID] ?? 0) == generation { s.snapshots[key] = built }
        }
        return built
    }

    /// Alla kandidater för typen i en fråga: katalog ⟕ matchning ⟕ cachad metadata. Bara de fält som behövs
    /// plockas ur JSON-blobben (`json_extract` med flera sökvägar tolkar blobben en gång per rad), och resultatet
    /// avkodas med en liten `Decodable`.
    private func build(playlistID: UUID, kind: ContentKind) throws -> Snapshot {
        let table = kind == .movie ? "movie" : "series"
        let decoder = JSONDecoder()
        var candidates: [Candidate] = []
        var infos: [Info] = []
        try library.db.writer.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.providerID, c.title, c.year, c.posterURL, c.addedAt,
                       COALESCE(c.tmdbID, t.tmdbID) AS effective,
                       json_extract(m.json, '$.ageLimit', '$.popularity', '$.genres', '$.cast', '$.directors',
                                    '$.creators', '$.keywords') AS features
                FROM \(table) c
                LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?2 AND t.providerID = c.providerID
                LEFT JOIN tmdbTitle m ON m.kind = ?2 AND m.tmdbID = COALESCE(c.tmdbID, t.tmdbID)
                WHERE c.playlistID = ?1
                """, arguments: [playlistID.uuidString, kind.rawValue])
            while let row = try rows.next() {
                let providerID: String = row[0]
                let title: String = row[1]
                let added: Double? = row[4]
                let tmdbID: Int? = row[5]
                let featuresJSON: String? = row[6]
                let f = featuresJSON.flatMap { try? decoder.decode(Features.self, from: Data($0.utf8)) } ?? Features()
                candidates.append(Candidate(
                    ref: ItemRef(kind: kind, providerID: providerID), tmdbID: tmdbID, title: title, genres: f.genres,
                    castIDs: f.cast, directorIDs: f.directors, keywords: f.keywords, ageLimit: f.age,
                    addedAt: added.map(Date.init(timeIntervalSince1970:)), popularity: f.popularity))
                infos.append(Info(index: 0, title: title, year: row[2], poster: row[3], tmdbID: tmdbID,
                                  ageLimit: f.age))
            }
        }
        // Sortera index en gång och bygg båda ordningarna.
        let order = candidates.indices.sorted { Self.byPopularity(candidates[$0], candidates[$1]) }
        var snap = Snapshot()
        snap.candidates.reserveCapacity(order.count)
        snap.info.reserveCapacity(order.count)
        for (i, j) in order.enumerated() {
            snap.candidates.append(candidates[j])
            var info = infos[j]
            info.index = i
            // Dubbletter av providerID kan inte förekomma (UNIQUE), men behåll första vid behov.
            if snap.info[candidates[j].ref.providerID] == nil { snap.info[candidates[j].ref.providerID] = info }
        }
        snap.byAdded = snap.candidates.filter { $0.addedAt != nil }.sorted { a, b in
            if a.addedAt! != b.addedAt! { return a.addedAt! > b.addedAt! }
            return Self.refLess(a.ref, b.ref)
        }
        return snap
    }

    /// Heltalslistor (t.ex. `$.similar`, `$.recommendations`) ur cachad metadata per TMDB-id.
    private func intLists(kind: ContentKind, tmdbIDs: [Int], path: String) throws -> [Int: [Int]] {
        guard !tmdbIDs.isEmpty else { return [:] }
        var out: [Int: [Int]] = [:]
        let decoder = JSONDecoder()
        for start in stride(from: 0, to: tmdbIDs.count, by: 500) {
            let chunk = Array(tmdbIDs[start..<min(start + 500, tmdbIDs.count)])
            let placeholders = (0..<chunk.count).map { "?\($0 + 3)" }.joined(separator: ",")
            var args: StatementArguments = [kind.rawValue, path]
            args += StatementArguments(chunk)
            let rows = try library.db.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT tmdbID, json_extract(json, ?2) AS list FROM tmdbTitle
                    WHERE kind = ?1 AND tmdbID IN (\(placeholders))
                    """, arguments: args)
            }
            for row in rows {
                let list: String? = row["list"]
                if let list, let ids = try? decoder.decode([Int].self, from: Data(list.utf8)) { out[row["tmdbID"]] = ids }
            }
        }
        return out
    }

    /// `trending.<typ>` från TMDB-listcachen, annars `popular.<typ>.SE`, annars tomt.
    private func rankedTMDBIDs(kind: ContentKind) throws -> [Int] {
        let suffix = kind == .movie ? "movie" : "series"
        if let trending = try metadata.list("trending.\(suffix)") { return trending.ids }
        return try metadata.list("popular.\(suffix).SE")?.ids ?? []
    }

    /// Genrerna med flest kandidater, flest först (lika: lägst id först).
    static func largestGenres(_ candidates: [Candidate], count: Int) -> [Int] {
        var counts: [Int: Int] = [:]
        for c in candidates { for g in Set(c.genres) { counts[g, default: 0] += 1 } }
        return counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(count).map(\.key)
    }

    private static func kidsAllowed(_ age: Int?) -> Bool {
        guard let age else { return false }
        return age <= Certification.kidsMaxAge
    }

    private static func item(_ ref: ItemRef, _ snaps: [ContentKind: Snapshot]) -> LibraryItem? {
        guard let info = snaps[ref.kind]?.info[ref.providerID] else { return nil }
        return LibraryItem(kind: ref.kind, providerID: ref.providerID, title: info.title, year: info.year,
                           posterURL: info.poster.flatMap { URL(string: $0) })
    }

    /// Samma ordning som `DiscoveryEngine` använder internt (popularitet, sedan typ och `providerID`).
    private static func byPopularity(_ a: Candidate, _ b: Candidate) -> Bool {
        let pa = a.popularity ?? -Double.infinity, pb = b.popularity ?? -Double.infinity
        if pa != pb { return pa > pb }
        return refLess(a.ref, b.ref)
    }

    private static func refLess(_ a: ItemRef, _ b: ItemRef) -> Bool {
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        return a.providerID < b.providerID
    }
}

/// Delmängd av `TitleMetadata` i ordningen från `json_extract`: ålder, popularitet, genrer, skådespelare,
/// regissörer, serieskapare och nyckelord.
private struct Features: Decodable {
    var age: Int?
    var popularity: Double?
    var genres: [Int] = []
    var cast: [Int] = []
    var directors: [Int] = []
    var keywords: [String] = []

    private struct ID: Decodable { let id: Int }

    init() {}

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        age = try c.decodeIfPresent(Int.self)
        popularity = try c.decodeIfPresent(Double.self)
        genres = try c.decodeIfPresent([ID].self)?.map(\.id) ?? []
        cast = try c.decodeIfPresent([ID].self)?.map(\.id) ?? []
        let directors = try c.decodeIfPresent([ID].self)?.map(\.id) ?? []
        let creators = try c.decodeIfPresent([ID].self)?.map(\.id) ?? []
        self.directors = directors + creators
        keywords = try c.decodeIfPresent([String].self) ?? []
    }
}
