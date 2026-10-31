import Core
import Foundation
import GRDB

/// Lagring för tablån (EPG): program per spellista och kanal, senaste hämtning och manuell kanaluppdelning.
public final class EPGStore: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Program

    /// Atomär: allt eller inget. Tidigare program för spellistan ersätts bara om batchen skrivs klart; ett fel
    /// (t.ex. ett ogiltigt program) rullar tillbaka hela transaktionen, så att gamla program och `lastFetch` består.
    public func replacePrograms(playlistID: UUID, programs: any Sequence<EPGProgram>, fetchedAt: Date) throws {
        let pid = playlistID.uuidString
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM epgProgram WHERE playlistID = ?", arguments: [pid])
            let insert = try db.makeStatement(sql: """
                INSERT INTO epgProgram (playlistID, channelID, start, "end", title, summary)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            for p in programs {
                try insert.execute(arguments: [
                    pid, p.channelID, p.start.timeIntervalSince1970, p.end.timeIntervalSince1970, p.title, p.summary,
                ])
            }
            try db.execute(sql: """
                INSERT INTO epgMeta (playlistID, fetchedAt) VALUES (?, ?)
                ON CONFLICT(playlistID) DO UPDATE SET fetchedAt = excluded.fetchedAt
                """, arguments: [pid, fetchedAt.timeIntervalSince1970])
        }
    }

    /// Program som överlappar `range` (börjar före eller vid slutet och slutar efter början), per kanal i starttid.
    /// Varje efterfrågad kanal får en post; kanaler utan program ger en tom lista.
    public func programs(playlistID: UUID, channelIDs: [String], in range: ClosedRange<Date>) throws
        -> [String: [EPGProgram]] {
        let pid = playlistID.uuidString
        let lower = range.lowerBound.timeIntervalSince1970
        let upper = range.upperBound.timeIntervalSince1970
        return try db.writer.read { db in
            let st = try db.makeStatement(sql: """
                SELECT channelID, start, "end", title, summary FROM epgProgram
                WHERE playlistID = ?1 AND channelID = ?2 AND start <= ?4 AND "end" > ?3
                ORDER BY start, rowid
                """)
            var result: [String: [EPGProgram]] = [:]
            for channel in channelIDs {
                let rows = try Row.fetchAll(st, arguments: [pid, channel, lower, upper])
                result[channel] = rows.map(Self.program)
            }
            return result
        }
    }

    /// Pågående program (`start <= at < end`) och nästa (första som börjar vid det pågåendes slut, annars vid eller
    /// efter `at`). Kanaler utan något av dem utelämnas.
    public func nowNext(playlistID: UUID, channelIDs: [String], at date: Date) throws -> [String: NowNext] {
        let pid = playlistID.uuidString
        let at = date.timeIntervalSince1970
        return try db.writer.read { db in
            let nowStatement = try db.makeStatement(sql: """
                SELECT channelID, start, "end", title, summary FROM epgProgram
                WHERE playlistID = ?1 AND channelID = ?2 AND start <= ?3 AND "end" > ?3
                ORDER BY start DESC, rowid LIMIT 1
                """)
            let nextStatement = try db.makeStatement(sql: """
                SELECT channelID, start, "end", title, summary FROM epgProgram
                WHERE playlistID = ?1 AND channelID = ?2 AND start >= ?3
                ORDER BY start, rowid LIMIT 1
                """)
            var result: [String: NowNext] = [:]
            for channel in channelIDs {
                let now = try Row.fetchOne(nowStatement, arguments: [pid, channel, at]).map(Self.program)
                let after = now?.end.timeIntervalSince1970 ?? at
                let next = try Row.fetchOne(nextStatement, arguments: [pid, channel, after]).map(Self.program)
                if now != nil || next != nil {
                    result[channel] = NowNext(now: now, next: next)
                }
            }
            return result
        }
    }

    public func lastFetch(playlistID: UUID) throws -> Date? {
        try db.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT fetchedAt FROM epgMeta WHERE playlistID = ?",
                                arguments: [playlistID.uuidString]).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Raderar program som slutat före `before` (alla spellistor).
    public func prune(before: Date) throws {
        try db.writer.write { db in
            try db.execute(sql: #"DELETE FROM epgProgram WHERE "end" < ?"#,
                           arguments: [before.timeIntervalSince1970])
        }
    }

    // MARK: - Manuell kanaluppdelning

    public func splitProviderIDs(playlistID: UUID) throws -> Set<String> {
        try db.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT providerID FROM channelSplit WHERE playlistID = ?",
                                    arguments: [playlistID.uuidString]))
        }
    }

    public func setSplit(playlistID: UUID, providerID: String, split: Bool) throws {
        try db.writer.write { db in
            if split {
                try db.execute(sql: "INSERT OR IGNORE INTO channelSplit (playlistID, providerID) VALUES (?, ?)",
                               arguments: [playlistID.uuidString, providerID])
            } else {
                try db.execute(sql: "DELETE FROM channelSplit WHERE playlistID = ? AND providerID = ?",
                               arguments: [playlistID.uuidString, providerID])
            }
        }
    }

    // MARK: - Hjälpare

    private static func program(_ row: Row) -> EPGProgram {
        EPGProgram(channelID: row["channelID"], start: Date(timeIntervalSince1970: row["start"]),
                   end: Date(timeIntervalSince1970: row["end"]), title: row["title"], summary: row["summary"])
    }
}
