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

    /// Spellistans titlar av typen `kind` som kandidater, i ingen särskild ordning (motorn står för all rankning).
    /// Titlar utan metadata ingår med tomma egenskaper. Live ger en tom lista.
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

        let signals = try self.signals(playlistID: playlistID, personal: personal, userState: userState, snaps: snaps)
        add(.forYou, items(DiscoveryEngine.forYou(candidates: order.flatMap { pools[$0] ?? [] }, signals: signals,
                                                 limit: Self.rowLimit)))

        for k in [ContentKind.movie, .series] where order.contains(k) {
            let ranked = try rankedTMDBIDs(kind: k)
            add(.topTen(k), items(DiscoveryEngine.topTen(rankedTMDBIDs: ranked, candidates: pools[k] ?? [])))
        }

        for k in order {
            add(.recentlyAdded(k), items(DiscoveryEngine.recentlyAdded(candidates: pools[k] ?? [],
                                                                       limit: Self.rowLimit)))
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
        /// I frågans ordning (odefinierad); `Info.index` pekar hit.
        var candidates: [Candidate] = []
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

    /// Frågan bakom kandidaterna: katalog ⟕ matchning ⟕ cachad metadata (effektivt id: leverantörens först).
    /// Blobben hämtas rå; att låta SQLite plocka fälten (`json_extract`/`json_each`) mättes som långsammare än
    /// `FeatureScanner`, som bara läser de fält som behövs.
    static func candidatesSQL(kind: ContentKind) -> String {
        let table = kind == .movie ? "movie" : "series"
        return """
            SELECT c.providerID, c.title, c.year, c.posterURL, c.addedAt,
                   COALESCE(c.tmdbID, t.tmdbID) AS effective, m.json
            FROM \(table) c
            LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?2 AND t.providerID = c.providerID
            LEFT JOIN tmdbTitle m ON m.kind = ?2 AND m.tmdbID = COALESCE(c.tmdbID, t.tmdbID)
            WHERE c.playlistID = ?1
            """
    }

    /// Alla kandidater för typen i en fråga (`candidatesSQL`). Blobben tolkas med
    /// `FeatureScanner` (utan `JSONDecoder`); oväntat format faller tillbaka på `JSONDecoder`, och oläsbar data
    /// ger en kandidat utan egenskaper.
    private func build(playlistID: UUID, kind: ContentKind) throws -> Snapshot {
        var snap = Snapshot()
        try library.db.writer.read { db in
            let rows = try Row.fetchCursor(db, sql: Self.candidatesSQL(kind: kind),
                                           arguments: [playlistID.uuidString, kind.rawValue])
            while let row = try rows.next() {
                let providerID: String = row[0]
                let title: String = row[1]
                let added: Double? = row[4]
                let tmdbID: Int? = row[5]
                let featuresJSON: String? = row[6]
                let f = featuresJSON.map(Features.parse) ?? Features()
                // providerID är unikt per spellista och typ (UNIQUE i katalogtabellen).
                snap.info[providerID] = Info(index: snap.candidates.count, title: title, year: row[2],
                                             poster: row[3], tmdbID: tmdbID, ageLimit: f.age)
                snap.candidates.append(Candidate(
                    ref: ItemRef(kind: kind, providerID: providerID), tmdbID: tmdbID, title: title, genres: f.genres,
                    castIDs: f.cast, directorIDs: f.directors, keywords: f.keywords, ageLimit: f.age,
                    addedAt: added.map(Date.init(timeIntervalSince1970:)), popularity: f.popularity))
            }
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
        for c in candidates {
            for (i, g) in c.genres.enumerated() where !c.genres[..<i].contains(g) { counts[g, default: 0] += 1 }
        }
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
}

/// Delmängd av `TitleMetadata` som kandidaterna behöver. Serieskapare räknas som regissörer.
struct Features: Decodable, Equatable {
    var age: Int?
    var popularity: Double?
    var genres: [Int] = []
    var cast: [Int] = []
    var directors: [Int] = []
    var keywords: [String] = []

    private struct ID: Decodable { let id: Int }

    init() {}

    /// Snabbtolkning med `FeatureScanner`, annars `JSONDecoder`, annars inga egenskaper.
    static func parse(_ json: String) -> Features {
        var text = json
        if let f = text.withUTF8({ buf -> Features? in
            var scanner = FeatureScanner(bytes: buf)
            return scanner.features()
        }) { return f }
        return (try? JSONDecoder().decode(Features.self, from: Data(json.utf8))) ?? Features()
    }

    private enum CodingKeys: String, CodingKey {
        case ageLimit, popularity, genres, cast, directors, creators, keywords
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age = try c.decodeIfPresent(Int.self, forKey: .ageLimit)
        popularity = try c.decodeIfPresent(Double.self, forKey: .popularity)
        genres = try c.decodeIfPresent([ID].self, forKey: .genres)?.map(\.id) ?? []
        cast = try c.decodeIfPresent([ID].self, forKey: .cast)?.map(\.id) ?? []
        let directors = try c.decodeIfPresent([ID].self, forKey: .directors)?.map(\.id) ?? []
        let creators = try c.decodeIfPresent([ID].self, forKey: .creators)?.map(\.id) ?? []
        self.directors = directors + creators
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

/// Minimal JSON-läsare för den cachade `TitleMetadata`-blobben. Läser `ageLimit`, `popularity`, `id` ur objekten i
/// `genres`, `cast`, `directors` och `creators` samt strängarna i `keywords` och hoppar över allt annat (även
/// `overview` och övriga långa fält) utan att skapa några objekt. Returnerar `nil` vid allt oväntat (då används
/// `JSONDecoder`).
struct FeatureScanner {
    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

    let bytes: UnsafeBufferPointer<UInt8>
    private var i = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func features() -> Features? {
        var f = Features()
        var creators: [Int] = []
        guard expect("{") else { return nil }
        if !expect("}") {
            repeat {
                guard let key = key(), expect(":") else { return nil }
                switch key {
                case .ageLimit:
                    guard let a = optionalNumber() else { return nil }
                    if let a {
                        guard let n = Int(exactly: a) else { return nil }
                        f.age = n
                    }
                case .popularity:
                    guard let p = optionalNumber() else { return nil }
                    f.popularity = p
                case .genres:
                    guard let ids = idArray() else { return nil }
                    f.genres = ids
                case .cast:
                    guard let ids = idArray() else { return nil }
                    f.cast = ids
                case .directors:
                    guard let ids = idArray() else { return nil }
                    f.directors = ids
                case .creators:
                    guard let ids = idArray() else { return nil }
                    creators = ids
                case .keywords:
                    guard let kws = stringArray() else { return nil }
                    f.keywords = kws
                case .other:
                    guard skipValue() else { return nil }
                }
            } while expect(",")
            guard expect("}") else { return nil }
        }
        skipWS()
        guard i == bytes.count else { return nil }
        f.directors += creators
        return f
    }

    private enum Key { case ageLimit, popularity, genres, cast, directors, creators, keywords, other }

    private static let keys: [(name: [UInt8], key: Key)] = [
        (Array("ageLimit".utf8), .ageLimit), (Array("popularity".utf8), .popularity), (Array("genres".utf8), .genres),
        (Array("cast".utf8), .cast), (Array("directors".utf8), .directors), (Array("creators".utf8), .creators),
        (Array("keywords".utf8), .keywords),
    ]

    /// Läser en nyckel på toppnivå. Nycklar med escape-sekvenser räknas som okända (TitleMetadata har inga sådana).
    private mutating func key() -> Key? {
        skipWS()
        let start = i
        guard skipString() else { return nil }
        let name = UnsafeBufferPointer(rebasing: bytes[(start + 1)..<(i - 1)])
        for entry in Self.keys where entry.name.count == name.count && entry.name.elementsEqual(name) {
            return entry.key
        }
        return .other
    }

    private mutating func skipWS() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    private mutating func expect(_ c: Unicode.Scalar) -> Bool {
        skipWS()
        guard i < bytes.count, bytes[i] == UInt8(ascii: c) else { return false }
        i += 1
        return true
    }

    private mutating func null() -> Bool {
        skipWS()
        guard i + 4 <= bytes.count, bytes[i] == UInt8(ascii: "n"), bytes[i + 1] == UInt8(ascii: "u"),
              bytes[i + 2] == UInt8(ascii: "l"), bytes[i + 3] == UInt8(ascii: "l") else { return false }
        i += 4
        return true
    }

    /// `.some(nil)` för `null`, `.some(tal)` för ett tal, `nil` vid fel.
    private mutating func optionalNumber() -> Double?? {
        if null() { return .some(nil) }
        guard let n = number() else { return nil }
        return .some(n)
    }

    private mutating func number() -> Double? {
        skipWS()
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 } else { break }
        }
        guard i > start else { return nil }
        // Heltal (vanligast) utan att skapa en sträng.
        var j = start, negative = false
        if bytes[j] == UInt8(ascii: "-") { negative = true; j += 1 }
        if j < i, i - j <= 15 {
            var value = 0, digitsOnly = true
            for k in j..<i {
                let d = bytes[k]
                guard d >= 0x30 && d <= 0x39 else { digitsOnly = false; break }
                value = value * 10 + Int(d - 0x30)
            }
            if digitsOnly { return Double(negative ? -value : value) }
        }
        return Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self))
    }

    /// `null` eller en array av objekt; `id` (heltal) plockas ur varje objekt, övriga nycklar hoppas över.
    private mutating func idArray() -> [Int]? {
        if null() { return [] }
        guard expect("[") else { return nil }
        var out: [Int] = []
        if expect("]") { return out }
        repeat {
            guard expect("{") else { return nil }
            var id: Int?
            if !expect("}") {
                repeat {
                    guard let isID = keyIsID(), expect(":") else { return nil }
                    if isID {
                        guard let n = number(), let v = Int(exactly: n) else { return nil }
                        id = v
                    } else {
                        guard skipValue() else { return nil }
                    }
                } while expect(",")
                guard expect("}") else { return nil }
            }
            guard let id else { return nil }
            out.append(id)
        } while expect(",")
        guard expect("]") else { return nil }
        return out
    }

    private mutating func stringArray() -> [String]? {
        if null() { return [] }
        guard expect("[") else { return nil }
        var out: [String] = []
        if expect("]") { return out }
        repeat {
            guard let s = string() else { return nil }
            out.append(s)
        } while expect(",")
        guard expect("]") else { return nil }
        return out
    }

    /// Läser en nyckel och svarar om den är exakt `id`.
    private mutating func keyIsID() -> Bool? {
        skipWS()
        let start = i
        guard skipString() else { return nil }
        return i - start == 4 && bytes[start + 1] == UInt8(ascii: "i") && bytes[start + 2] == UInt8(ascii: "d")
    }

    /// Hoppar över en sträng (inklusive citattecken); `false` vid fel.
    private mutating func skipString() -> Bool {
        skipWS()
        guard i < bytes.count, bytes[i] == Self.quote else { return false }
        i += 1
        while i < bytes.count {
            let c = bytes[i]
            if c == Self.backslash { i += 2; continue }
            i += 1
            if c == Self.quote { return true }
        }
        return false
    }

    /// Läser en sträng. Utan escape-sekvenser direkt ur byten; annars via `JSONDecoder` för exakt avkodning.
    private mutating func string() -> String? {
        skipWS()
        let start = i
        guard skipString() else { return nil }
        let inner = UnsafeBufferPointer(rebasing: bytes[(start + 1)..<(i - 1)])
        if !inner.contains(Self.backslash) { return String(decoding: inner, as: UTF8.self) }
        return try? JSONDecoder().decode(String.self, from: Data(UnsafeBufferPointer(rebasing: bytes[start..<i])))
    }

    /// Hoppar över ett godtyckligt värde.
    private mutating func skipValue() -> Bool {
        skipWS()
        guard i < bytes.count else { return false }
        let first = bytes[i]
        if first == Self.quote { return skipString() }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            while i < bytes.count {
                let c = bytes[i]
                if c == Self.quote {
                    guard skipString() else { return false }
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                }
                i += 1
            }
            return false
        }
        let start = i
        while i < bytes.count, bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "}"),
              bytes[i] != UInt8(ascii: "]") {
            i += 1
        }
        return i > start
    }
}
