import Core
import Foundation
import GRDB
import Metadata

/// Lagring för TMDB-metadata: cachad titelmetadata (global), matchningar per spellista, genrer och listor.
public final class MetadataStore: Sendable {
    /// En misslyckad matchning (utan id) försöks igen först efter så här lång tid.
    public static let unmatchedRetryInterval: TimeInterval = 7 * 24 * 3600

    let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Titelmetadata

    public func metadata(kind: ContentKind, tmdbID: Int) throws -> TitleMetadata? {
        try cachedMetadata(kind: kind, tmdbID: tmdbID)?.metadata
    }

    /// Metadata tillsammans med när den hämtades (för TTL).
    public func cachedMetadata(kind: ContentKind, tmdbID: Int) throws -> (metadata: TitleMetadata, fetchedAt: Date)? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json, fetchedAt FROM tmdbTitle WHERE kind = ? AND tmdbID = ?",
                                             arguments: [kind.rawValue, tmdbID]) else { return nil }
            // Oläsbar cache (t.ex. äldre format) behandlas som saknad.
            guard let metadata = try? JSONDecoder().decode(TitleMetadata.self, from: Data((row["json"] as String).utf8))
            else { return nil }
            return (metadata: metadata, fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))
        }
    }

    /// Sparar metadata och ersätter titelns rader i `titleGenre`.
    public func saveMetadata(_ metadata: TitleMetadata, now: Date) throws {
        try db.writer.write { db in try Self.saveMetadata(metadata, now: now, in: db) }
    }

    // MARK: - Matchningar

    public func match(playlistID: UUID, kind: ContentKind, providerID: String) throws
        -> (tmdbID: Int?, confidence: Double, attemptedAt: Date)? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT tmdbID, confidence, attemptedAt FROM tmdbMatch
                WHERE playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: [playlistID.uuidString, kind.rawValue, providerID]) else { return nil }
            return (tmdbID: row["tmdbID"], confidence: row["confidence"],
                    attemptedAt: Date(timeIntervalSince1970: row["attemptedAt"]))
        }
    }

    /// Sparar ett matchningsförsök; `tmdbID == nil` betyder att ingen säker träff hittades.
    public func saveMatch(playlistID: UUID, kind: ContentKind, providerID: String, tmdbID: Int?, confidence: Double,
                          now: Date) throws {
        try db.writer.write { db in
            try Self.saveMatch(playlistID: playlistID, kind: kind, providerID: providerID, tmdbID: tmdbID,
                               confidence: confidence, now: now, in: db)
        }
    }

    /// Sparar ett berikningsresultat (matchning och eventuell metadata) i en transaktion.
    public func saveEnrichment(playlistID: UUID, kind: ContentKind, providerID: String, tmdbID: Int?,
                               confidence: Double, metadata: TitleMetadata?, now: Date) throws {
        try db.writer.write { db in
            try Self.saveMatch(playlistID: playlistID, kind: kind, providerID: providerID, tmdbID: tmdbID,
                               confidence: confidence, now: now, in: db)
            if let metadata { try Self.saveMetadata(metadata, now: now, in: db) }
        }
    }

    /// Effektivt TMDB-id: leverantörens `tmdbID` vinner, därefter matchningen.
    public func tmdbID(playlistID: UUID, kind: ContentKind, providerID: String) throws -> Int? {
        guard let table = Self.table(kind) else { return nil }
        return try db.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(c.tmdbID, t.tmdbID) FROM \(table) c
                LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?3 AND t.providerID = c.providerID
                WHERE c.playlistID = ?1 AND c.providerID = ?2
                """, arguments: [playlistID.uuidString, providerID, kind.rawValue])
        }
    }

    /// Poster utan matchrad, eller vars matchning saknar id och är äldre än 7 dagar. Nyast tillagda först.
    public func unmatchedItems(playlistID: UUID, kind: ContentKind, limit: Int, now: Date = Date()) throws
        -> [(providerID: String, title: String, year: Int?, providerTMDBID: Int?)] {
        guard let table = Self.table(kind), limit > 0 else { return [] }
        let cutoff = now.timeIntervalSince1970 - Self.unmatchedRetryInterval
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.providerID, c.title, c.year, c.tmdbID FROM \(table) c
                LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?2 AND t.providerID = c.providerID
                WHERE c.playlistID = ?1 AND (t.providerID IS NULL OR (t.tmdbID IS NULL AND t.attemptedAt < ?3))
                ORDER BY c.addedAt IS NULL, c.addedAt DESC, c.rowid
                LIMIT ?4
                """, arguments: [playlistID.uuidString, kind.rawValue, cutoff, limit]).map {
                (providerID: $0["providerID"], title: $0["title"], year: $0["year"], providerTMDBID: $0["tmdbID"])
            }
        }
    }

    // MARK: - Uppslag för hyllor

    /// Spellistans poster av typen `kind` vars effektiva TMDB-id har genren `genreID`, sorterade på titel.
    public func items(playlistID: UUID, kind: ContentKind, genreID: Int, limit: Int) throws -> [LibraryItem] {
        guard let table = Self.table(kind), limit > 0 else { return [] }
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.providerID, c.title, c.year, c.posterURL AS poster FROM \(table) c
                LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?2 AND t.providerID = c.providerID
                JOIN titleGenre g ON g.kind = ?2 AND g.tmdbID = COALESCE(c.tmdbID, t.tmdbID) AND g.genreID = ?3
                WHERE c.playlistID = ?1
                ORDER BY c.title COLLATE NOCASE, c.providerID
                LIMIT ?4
                """, arguments: [playlistID.uuidString, kind.rawValue, genreID, limit]).map { Self.item(kind, $0) }
        }
    }

    /// Poster för `tmdbIDs` i indataordning; id som saknas i spellistan hoppas över. Har flera poster samma id
    /// returneras bara en (lägst titel, sedan `providerID`).
    public func items(playlistID: UUID, kind: ContentKind, tmdbIDs: [Int]) throws -> [LibraryItem] {
        guard let table = Self.table(kind), !tmdbIDs.isEmpty else { return [] }
        var found: [Int: LibraryItem] = [:]
        // Bundna parametrar i omgångar (SQLite har en gräns för antalet).
        for chunk in stride(from: 0, to: tmdbIDs.count, by: 500).map({ Array(tmdbIDs[$0..<min($0 + 500, tmdbIDs.count)]) }) {
            let placeholders = (0..<chunk.count).map { "?\($0 + 3)" }.joined(separator: ",")
            var args: StatementArguments = [playlistID.uuidString, kind.rawValue]
            args += StatementArguments(chunk)
            let rows = try db.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(c.tmdbID, t.tmdbID) AS effective, c.providerID, c.title, c.year,
                           c.posterURL AS poster
                    FROM \(table) c
                    LEFT JOIN tmdbMatch t ON t.playlistID = c.playlistID AND t.kind = ?2 AND t.providerID = c.providerID
                    WHERE c.playlistID = ?1 AND COALESCE(c.tmdbID, t.tmdbID) IN (\(placeholders))
                    ORDER BY c.title COLLATE NOCASE, c.providerID
                    """, arguments: args)
            }
            for row in rows {
                let id: Int = row["effective"]
                if found[id] == nil { found[id] = Self.item(kind, row) }
            }
        }
        var seen = Set<Int>()
        return tmdbIDs.compactMap { id in seen.insert(id).inserted ? found[id] : nil }
    }

    // MARK: - Listor

    public func list(_ name: String) throws -> (ids: [Int], fetchedAt: Date)? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT ids, fetchedAt FROM tmdbList WHERE name = ?",
                                             arguments: [name]) else { return nil }
            let ids = (try? JSONDecoder().decode([Int].self, from: Data((row["ids"] as String).utf8))) ?? []
            return (ids: ids, fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))
        }
    }

    public func saveList(_ name: String, ids: [Int], now: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO tmdbList (name, ids, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [name, json, now.timeIntervalSince1970])
        }
    }

    // MARK: - Hjälpare

    private static func table(_ kind: ContentKind) -> String? {
        switch kind {
        case .movie: "movie"
        case .series: "series"
        case .live: nil
        }
    }

    private static func item(_ kind: ContentKind, _ row: Row) -> LibraryItem {
        let poster: String? = row["poster"]
        return LibraryItem(kind: kind, providerID: row["providerID"], title: row["title"], year: row["year"],
                           posterURL: poster.flatMap { URL(string: $0) })
    }

    private static func saveMatch(playlistID: UUID, kind: ContentKind, providerID: String, tmdbID: Int?,
                                  confidence: Double, now: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [playlistID.uuidString, kind.rawValue, providerID, tmdbID, confidence,
                             now.timeIntervalSince1970])
    }

    private static func saveMetadata(_ metadata: TitleMetadata, now: Date, in db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(metadata), as: UTF8.self)
        let kind = metadata.kind.rawValue
        try db.execute(sql: """
            INSERT OR REPLACE INTO tmdbTitle (kind, tmdbID, language, json, fetchedAt) VALUES (?, ?, ?, ?, ?)
            """, arguments: [kind, metadata.tmdbID, metadata.language, json, now.timeIntervalSince1970])
        try db.execute(sql: "DELETE FROM titleGenre WHERE kind = ? AND tmdbID = ?", arguments: [kind, metadata.tmdbID])
        for genre in Set(metadata.genres.map(\.id)) {
            try db.execute(sql: "INSERT INTO titleGenre (kind, tmdbID, genreID) VALUES (?, ?, ?)",
                           arguments: [kind, metadata.tmdbID, genre])
        }
    }
}
