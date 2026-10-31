import Core
import Foundation
import GRDB
import Providers

public final class LibraryStore: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Spellistor

    public func upsertPlaylist(_ p: Playlist) throws {
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO playlist (id, name, kind, createdAt, lastImportedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, kind = excluded.kind,
                    lastImportedAt = COALESCE(excluded.lastImportedAt, playlist.lastImportedAt)
                """, arguments: [p.id.uuidString, p.name, p.kind.rawValue,
                                 p.createdAt.timeIntervalSince1970, p.lastImportedAt?.timeIntervalSince1970])
        }
    }

    public func deletePlaylist(_ id: UUID) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM searchIndex WHERE playlistID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func playlists() throws -> [Playlist] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playlist ORDER BY createdAt, name").compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let kind = PlaylistSourceKind(rawValue: row["kind"]) else { return nil }
                let imported: Double? = row["lastImportedAt"]
                return Playlist(id: id, name: row["name"], kind: kind,
                                createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                                lastImportedAt: imported.map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    // MARK: - Katalogersättning

    /// Ersätter hela katalogen för spellistan i en enda transaktion. Befintliga poster behåller `firstSeenAt`,
    /// poster som saknas i `catalog` raderas. Dubbletter av `providerID` inom en typ: sista vinner.
    public func replaceCatalog(_ catalog: ProviderCatalog, playlistID: UUID, now: Date) throws {
        let pid = playlistID.uuidString
        let ts = now.timeIntervalSince1970

        try db.writer.write { db in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func json(_ l: StreamLocator) throws -> String {
                String(decoding: try encoder.encode(l), as: UTF8.self)
            }
            // Markera allt som inaktuellt (-1); upsert sätter updatedAt = now, resten raderas efteråt.
            for table in ["movie", "series", "liveStream"] {
                try db.execute(sql: "UPDATE \(table) SET updatedAt = -1 WHERE playlistID = ?", arguments: [pid])
            }
            // Xtream hämtar avsnitt vid behov: då behålls befintliga avsnitt (utom för borttagna serier).
            if catalog.episodesComplete {
                try db.execute(sql: "UPDATE episode SET updatedAt = -1 WHERE playlistID = ?", arguments: [pid])
            }

            try db.execute(sql: "DELETE FROM category WHERE playlistID = ?", arguments: [pid])
            let cat = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO category (playlistID, kind, providerID, name, sortIndex) VALUES (?, ?, ?, ?, ?)
                """)
            for c in catalog.categories {
                try cat.execute(arguments: [pid, c.kind.rawValue, c.providerID, c.name, c.sortIndex])
            }

            let movie = try db.makeStatement(sql: """
                INSERT INTO movie (playlistID, providerID, title, year, categoryID, posterURL, container, tmdbID,
                                   rating, addedAt, locator, firstSeenAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(playlistID, providerID) DO UPDATE SET
                    title = excluded.title, year = excluded.year, categoryID = excluded.categoryID,
                    posterURL = excluded.posterURL, container = excluded.container,
                    tmdbID = COALESCE(excluded.tmdbID, movie.tmdbID),
                    rating = excluded.rating, addedAt = excluded.addedAt, locator = excluded.locator,
                    updatedAt = excluded.updatedAt
                """)
            for m in catalog.movies {
                try movie.execute(arguments: [
                    pid, m.providerID, m.title, m.year, m.categoryID, m.posterURL?.absoluteString, m.container,
                    m.tmdbID, m.rating, m.addedAt?.timeIntervalSince1970, try json(m.locator), ts, ts,
                ])
            }

            let series = try db.makeStatement(sql: """
                INSERT INTO series (playlistID, providerID, title, year, categoryID, posterURL, tmdbID, rating,
                                    addedAt, firstSeenAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(playlistID, providerID) DO UPDATE SET
                    title = excluded.title, year = excluded.year, categoryID = excluded.categoryID,
                    posterURL = excluded.posterURL, tmdbID = COALESCE(excluded.tmdbID, series.tmdbID),
                    rating = excluded.rating,
                    addedAt = excluded.addedAt, updatedAt = excluded.updatedAt
                """)
            for s in catalog.series {
                try series.execute(arguments: [
                    pid, s.providerID, s.title, s.year, s.categoryID, s.posterURL?.absoluteString, s.tmdbID,
                    s.rating, s.addedAt?.timeIntervalSince1970, ts, ts,
                ])
            }

            let episode = try db.makeStatement(sql: """
                INSERT INTO episode (playlistID, providerID, seriesProviderID, season, number, title, container,
                                     locator, stillURL, overview, durationSeconds, detailsFetched, firstSeenAt,
                                     updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(playlistID, providerID) DO UPDATE SET
                    seriesProviderID = excluded.seriesProviderID, season = excluded.season,
                    number = excluded.number, title = excluded.title, container = excluded.container,
                    locator = excluded.locator, stillURL = excluded.stillURL, overview = excluded.overview,
                    durationSeconds = excluded.durationSeconds, detailsFetched = 1, updatedAt = excluded.updatedAt
                """)
            for e in catalog.episodes {
                try episode.execute(arguments: [
                    pid, e.providerID, e.seriesProviderID, e.season, e.number, e.title, e.container,
                    try json(e.locator), e.stillURL?.absoluteString, e.overview, e.durationSeconds, ts, ts,
                ])
            }

            let live = try db.makeStatement(sql: """
                INSERT INTO liveStream (playlistID, providerID, name, categoryID, logoURL, epgChannelID, locator,
                                        firstSeenAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(playlistID, providerID) DO UPDATE SET
                    name = excluded.name, categoryID = excluded.categoryID, logoURL = excluded.logoURL,
                    epgChannelID = excluded.epgChannelID, locator = excluded.locator,
                    updatedAt = excluded.updatedAt
                """)
            for l in catalog.live {
                try live.execute(arguments: [
                    pid, l.providerID, l.name, l.categoryID, l.logoURL?.absoluteString, l.epgChannelID,
                    try json(l.locator), ts, ts,
                ])
            }

            for table in ["movie", "series", "liveStream"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE playlistID = ? AND updatedAt = -1", arguments: [pid])
            }
            if catalog.episodesComplete {
                try db.execute(sql: "DELETE FROM episode WHERE playlistID = ? AND updatedAt = -1", arguments: [pid])
            } else {
                try db.execute(sql: """
                    DELETE FROM episode WHERE playlistID = ?1 AND seriesProviderID NOT IN
                        (SELECT providerID FROM series WHERE playlistID = ?1)
                    """, arguments: [pid])
            }

            try db.execute(sql: "DELETE FROM searchIndex WHERE playlistID = ?", arguments: [pid])
            try db.execute(sql: """
                INSERT INTO searchIndex (title, kind, playlistID, providerID)
                SELECT title, 'movie', playlistID, providerID FROM movie WHERE playlistID = ?1
                UNION ALL
                SELECT title, 'series', playlistID, providerID FROM series WHERE playlistID = ?1
                UNION ALL
                SELECT name, 'live', playlistID, providerID FROM liveStream WHERE playlistID = ?1
                """, arguments: [pid])

            try db.execute(sql: "UPDATE playlist SET lastImportedAt = ? WHERE id = ?", arguments: [ts, pid])
        }
    }

    // MARK: - Avsnitt, kontoinfo och uppslag

    /// Ersätter avsnitten för en serie i en transaktion. Oförändrade `providerID` behåller `firstSeenAt`.
    public func upsertEpisodes(_ episodes: [Episode], seriesProviderID: String, playlistID: UUID, now: Date) throws {
        let pid = playlistID.uuidString
        let ts = now.timeIntervalSince1970
        try db.writer.write { db in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try db.execute(sql: "UPDATE episode SET updatedAt = -1 WHERE playlistID = ? AND seriesProviderID = ?",
                           arguments: [pid, seriesProviderID])
            let st = try db.makeStatement(sql: """
                INSERT INTO episode (playlistID, providerID, seriesProviderID, season, number, title, container,
                                     locator, stillURL, overview, durationSeconds, detailsFetched, firstSeenAt,
                                     updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(playlistID, providerID) DO UPDATE SET
                    seriesProviderID = excluded.seriesProviderID, season = excluded.season,
                    number = excluded.number, title = excluded.title, container = excluded.container,
                    locator = excluded.locator, stillURL = excluded.stillURL, overview = excluded.overview,
                    durationSeconds = excluded.durationSeconds, detailsFetched = 1, updatedAt = excluded.updatedAt
                """)
            for e in episodes {
                try st.execute(arguments: [
                    pid, e.providerID, seriesProviderID, e.season, e.number, e.title, e.container,
                    String(decoding: try encoder.encode(e.locator), as: UTF8.self), e.stillURL?.absoluteString,
                    e.overview, e.durationSeconds, ts, ts,
                ])
            }
            try db.execute(sql: "DELETE FROM episode WHERE playlistID = ? AND seriesProviderID = ? AND updatedAt = -1",
                           arguments: [pid, seriesProviderID])
        }
    }

    public func episodes(playlistID: UUID, seriesProviderID: String) throws -> [Episode] {
        try db.writer.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: """
                SELECT providerID, season, number, title, container, locator, stillURL, overview, durationSeconds
                FROM episode
                WHERE playlistID = ? AND seriesProviderID = ? ORDER BY season, number, providerID
                """, arguments: [playlistID.uuidString, seriesProviderID]).map { row in
                Episode(providerID: row["providerID"], seriesProviderID: seriesProviderID, season: row["season"],
                        number: row["number"], title: row["title"], container: row["container"],
                        locator: try decoder.decode(StreamLocator.self, from: Data((row["locator"] as String).utf8)),
                        stillURL: (row["stillURL"] as String?).flatMap(URL.init(string:)),
                        overview: row["overview"], durationSeconds: row["durationSeconds"])
            }
        }
    }

    /// Sant när serien har lagrade avsnitt som aldrig skrivits av en hämtning med stillbild, beskrivning och längd
    /// (rader från före migreringen v5). Styr den enstaka omhämtningen; en hämtning markerar raderna, så att en
    /// leverantör som inte ger några uppgifter inte orsakar en hämtning vid varje öppning.
    public func episodesNeedDetails(playlistID: UUID, seriesProviderID: String) throws -> Bool {
        try db.writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM episode
                               WHERE playlistID = ? AND seriesProviderID = ? AND detailsFetched = 0)
                """, arguments: [playlistID.uuidString, seriesProviderID]) ?? false
        }
    }

    /// Gör att serien räknas som ännu inte omhämtad (`episodesNeedDetails` blir sant om den har avsnitt), t.ex. för
    /// en tvingad uppdatering eller test av omhämtningen.
    public func resetEpisodeDetailsFetched(playlistID: UUID, seriesProviderID: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE episode SET detailsFetched = 0 WHERE playlistID = ? AND seriesProviderID = ?",
                           arguments: [playlistID.uuidString, seriesProviderID])
        }
    }

    /// Markerar serien som omhämtad utan att röra avsnitten (leverantören gav inga avsnitt vid omhämtningen).
    public func markEpisodeDetailsFetched(playlistID: UUID, seriesProviderID: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE episode SET detailsFetched = 1 WHERE playlistID = ? AND seriesProviderID = ?",
                           arguments: [playlistID.uuidString, seriesProviderID])
        }
    }

    public func locator(playlistID: UUID, kind: ContentKind, providerID: String) throws -> StreamLocator? {
        let table = switch kind {
        case .movie: "movie"
        case .series: "episode"
        case .live: "liveStream"
        }
        return try db.writer.read { db in
            guard let text = try String.fetchOne(
                db, sql: "SELECT locator FROM \(table) WHERE playlistID = ? AND providerID = ?",
                arguments: [playlistID.uuidString, providerID]) else { return nil }
            return try JSONDecoder().decode(StreamLocator.self, from: Data(text.utf8))
        }
    }

    public func movie(playlistID: UUID, providerID: String) throws -> Movie? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT providerID, title, year, categoryID, posterURL, container, tmdbID, rating, addedAt, locator
                FROM movie WHERE playlistID = ? AND providerID = ?
                """, arguments: [playlistID.uuidString, providerID]) else { return nil }
            let poster: String? = row["posterURL"]
            let added: Double? = row["addedAt"]
            return Movie(providerID: row["providerID"], title: row["title"], year: row["year"],
                         categoryID: row["categoryID"], posterURL: poster.flatMap { URL(string: $0) },
                         container: row["container"], tmdbID: row["tmdbID"], rating: row["rating"],
                         addedAt: added.map(Date.init(timeIntervalSince1970:)),
                         locator: try JSONDecoder().decode(StreamLocator.self, from: Data((row["locator"] as String).utf8)))
        }
    }

    public func series(playlistID: UUID, providerID: String) throws -> Series? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT providerID, title, year, categoryID, posterURL, tmdbID, rating, addedAt
                FROM series WHERE playlistID = ? AND providerID = ?
                """, arguments: [playlistID.uuidString, providerID]) else { return nil }
            let poster: String? = row["posterURL"]
            let added: Double? = row["addedAt"]
            return Series(providerID: row["providerID"], title: row["title"], year: row["year"],
                          categoryID: row["categoryID"], posterURL: poster.flatMap { URL(string: $0) },
                          tmdbID: row["tmdbID"], rating: row["rating"],
                          addedAt: added.map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func accountInfo(playlistID: UUID) throws -> PlaylistAccountInfo {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT maxConnections, expiresAt, accountStatus FROM playlist WHERE id = ?",
                arguments: [playlistID.uuidString]) else {
                return PlaylistAccountInfo(maxConnections: nil, expiresAt: nil, status: nil)
            }
            let exp: Double? = row["expiresAt"]
            return PlaylistAccountInfo(maxConnections: row["maxConnections"],
                                       expiresAt: exp.map(Date.init(timeIntervalSince1970:)),
                                       status: row["accountStatus"])
        }
    }

    public func setAccountInfo(_ info: PlaylistAccountInfo, playlistID: UUID) throws {
        try db.writer.write { db in
            try db.execute(sql: """
                UPDATE playlist SET maxConnections = ?, expiresAt = ?, accountStatus = ? WHERE id = ?
                """, arguments: [info.maxConnections, info.expiresAt?.timeIntervalSince1970, info.status,
                                 playlistID.uuidString])
        }
    }

    /// Formatöversikt (containers per typ) för spellistans lagrade katalog, via `PlaylistStats`. Avsnitt räknas
    /// bara om de finns i databasen (Xtream hämtar dem vid behov).
    public func formatSummary(playlistID: UUID) throws -> FormatSummary {
        let pid = playlistID.uuidString
        let catalog: ProviderCatalog = try db.writer.read { db in
            let decoder = JSONDecoder()
            func locator(_ row: Row) throws -> StreamLocator {
                try decoder.decode(StreamLocator.self, from: Data((row["locator"] as String).utf8))
            }
            let movies = try Row.fetchAll(db, sql: "SELECT container, locator FROM movie WHERE playlistID = ?",
                                          arguments: [pid]).map {
                Movie(providerID: "", title: "", container: $0["container"], locator: try locator($0))
            }
            let episodes = try Row.fetchAll(db, sql: "SELECT container, locator FROM episode WHERE playlistID = ?",
                                            arguments: [pid]).map {
                Episode(providerID: "", seriesProviderID: "", season: 0, number: 0, title: "",
                        container: $0["container"], locator: try locator($0))
            }
            let live = try Row.fetchAll(db, sql: "SELECT locator FROM liveStream WHERE playlistID = ?",
                                        arguments: [pid]).map {
                LiveStream(providerID: "", name: "", locator: try locator($0))
            }
            let seriesCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE playlistID = ?",
                                               arguments: [pid]) ?? 0
            return ProviderCatalog(movies: movies,
                                   series: Array(repeating: Series(providerID: "", title: ""), count: seriesCount),
                                   episodes: episodes, live: live)
        }
        return PlaylistStats.summarize(catalog)
    }

    // MARK: - Läsning

    public func items(playlistID: UUID, kind: ContentKind, categoryID: String?, limit: Int, offset: Int) throws -> [LibraryItem] {
        let (table, titleColumn, posterColumn, yearColumn): (String, String, String, String) = switch kind {
        case .movie: ("movie", "title", "posterURL", "year")
        case .series: ("series", "title", "posterURL", "year")
        case .live: ("liveStream", "name", "logoURL", "NULL")
        }
        var sql = """
            SELECT providerID, \(titleColumn) AS title, \(yearColumn) AS year, \(posterColumn) AS poster
            FROM \(table) WHERE playlistID = ?
            """
        var args: StatementArguments = [playlistID.uuidString]
        if let categoryID {
            sql += " AND categoryID = ?"
            args += [categoryID]
        }
        sql += " ORDER BY \(titleColumn) COLLATE NOCASE, providerID LIMIT ? OFFSET ?"
        args += [limit, offset]
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { Self.item(kind: kind, $0) }
        }
    }

    public func categories(playlistID: UUID, kind: ContentKind) throws -> [Core.Category] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT providerID, name, sortIndex FROM category
                WHERE playlistID = ? AND kind = ? ORDER BY sortIndex, name
                """, arguments: [playlistID.uuidString, kind.rawValue]).map {
                Core.Category(providerID: $0["providerID"], name: $0["name"], kind: kind, sortIndex: $0["sortIndex"])
            }
        }
    }

    /// Rankning: titlar som börjar med hela frågan först, sedan bm25, sedan kortare titel, sedan rowid.
    /// `kind` begränsar träffarna till en typ (filtreras i SQL, före `limit`).
    public func search(_ query: String, playlistID: UUID, kind: ContentKind? = nil, limit: Int) throws -> [LibraryItem] {
        guard let (anchored, general) = Self.ftsQueries(query), limit > 0 else { return [] }
        let pid = playlistID.uuidString
        return try db.writer.read { db in
            let hits = try db.makeStatement(sql: """
                SELECT rowid, kind, providerID, title FROM searchIndex
                WHERE searchIndex MATCH ?1 AND playlistID = ?2 AND (?4 IS NULL OR kind = ?4)
                ORDER BY rank, length(title), rowid LIMIT ?3
                """)
            func run(_ match: String, _ n: Int) throws -> [Row] {
                try Row.fetchAll(hits, arguments: [match, pid, n, kind?.rawValue])
            }
            var rows = try run(anchored, limit)
            if rows.count < limit {
                var seen = Set(rows.map { $0["rowid"] as Int64 })
                for r in try run(general, limit + rows.count) where seen.insert(r["rowid"]).inserted {
                    rows.append(r)
                }
                rows = Array(rows.prefix(limit))
            }
            let details = try db.makeStatement(sql: """
                SELECT year, posterURL AS poster FROM movie WHERE playlistID = ?1 AND providerID = ?2 AND ?3 = 'movie'
                UNION ALL
                SELECT year, posterURL FROM series WHERE playlistID = ?1 AND providerID = ?2 AND ?3 = 'series'
                UNION ALL
                SELECT NULL, logoURL FROM liveStream WHERE playlistID = ?1 AND providerID = ?2 AND ?3 = 'live'
                """)
            return try rows.compactMap { row in
                guard let kind = ContentKind(rawValue: row["kind"]) else { return nil }
                let providerID: String = row["providerID"]
                let d = try Row.fetchOne(details, arguments: [pid, providerID, kind.rawValue])
                let poster: String? = d?["poster"]
                return LibraryItem(kind: kind, providerID: providerID, title: row["title"], year: d?["year"],
                                   posterURL: poster.flatMap { URL(string: $0) })
            }
        }
    }

    public func channelGroups(playlistID: UUID) throws -> [ChannelGroup] {
        let streams: [LiveStream] = try db.writer.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: """
                SELECT providerID, name, categoryID, logoURL, epgChannelID, locator
                FROM liveStream WHERE playlistID = ? ORDER BY rowid
                """, arguments: [playlistID.uuidString]).map { row in
                let locator = try decoder.decode(StreamLocator.self, from: Data((row["locator"] as String).utf8))
                let logo: String? = row["logoURL"]
                return LiveStream(providerID: row["providerID"], name: row["name"], categoryID: row["categoryID"],
                                  logoURL: logo.flatMap { URL(string: $0) }, epgChannelID: row["epgChannelID"],
                                  locator: locator)
            }
        }
        return ChannelGrouper.group(streams)
    }

    public func counts(playlistID: UUID) throws -> [ContentKind: Int] {
        try db.writer.read { db in
            let pid = playlistID.uuidString
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE playlistID = ?", arguments: [pid]) ?? 0
            }
            return [.movie: try count("movie"), .series: try count("series"), .live: try count("liveStream")]
        }
    }

    // MARK: - Hjälpare

    private static func item(kind: ContentKind, _ row: Row) -> LibraryItem {
        let poster: String? = row["poster"]
        return LibraryItem(kind: kind, providerID: row["providerID"], title: row["title"], year: row["year"],
                           posterURL: poster.flatMap { URL(string: $0) })
    }

    /// Delar indata i ord (bokstäver/siffror) och bygger två frågor: en förankrad fras (`^"ord1 ord2"*`, titeln
    /// börjar med frågan) och en allmän (`"ord1"* "ord2"*`). Alla FTS-specialtecken försvinner.
    static func ftsQueries(_ input: String) -> (anchored: String, general: String)? {
        let tokens = input.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else { return nil }
        return ("^\"" + tokens.joined(separator: " ") + "\"*",
                tokens.map { "\"\($0)\"*" }.joined(separator: " "))
    }
}
