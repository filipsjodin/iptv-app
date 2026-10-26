import Core
import Foundation
import GRDB
import Testing

@testable import Library

private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!

private func locatorJSON(_ l: StreamLocator) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(l), as: UTF8.self)
}

/// En databas från fas 1 (bara v1) uppgraderas till senaste schemat utan dataförlust.
@Test func v1DatabaseMigratesToLatest() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator.migrate(queue, upTo: "v1")
    try queue.write { db in
        try db.execute(sql: "INSERT INTO playlist (id, name, kind, createdAt, lastImportedAt) VALUES (?, ?, ?, ?, ?)",
                       arguments: [pid.uuidString, "Gammal", "xtream", 1000.0, 2000.0])
        try db.execute(sql: """
            INSERT INTO movie (playlistID, providerID, title, year, container, locator, firstSeenAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "m1", "Ett", 1999, "mkv",
                             try locatorJSON(.xtream(kind: .movie, streamID: "m1", container: "mkv")), 1.0, 1.0])
        try db.execute(sql: """
            INSERT INTO series (playlistID, providerID, title, firstSeenAt, updatedAt) VALUES (?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "s1", "Serie", 1.0, 1.0])
        try db.execute(sql: """
            INSERT INTO episode (playlistID, providerID, seriesProviderID, season, number, title, container, locator,
                                 firstSeenAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "e1", "s1", 1, 2, "Avsnitt", "mp4",
                             try locatorJSON(.xtream(kind: .series, streamID: "e1", container: "mp4")), 1.0, 1.0])
    }
    #expect(try queue.read { try $0.columns(in: "playlist").map(\.name) }.contains("maxConnections") == false)

    // Öppnar den befintliga databasen som appen gör: kör resterande migreringar.
    let store = LibraryStore(db: try AppDatabase(queue))

    try queue.read { db in
        let columns = Set(try db.columns(in: "playlist").map(\.name))
        #expect(columns.isSuperset(of: ["maxConnections", "expiresAt", "accountStatus"]))
        let row = try #require(try Row.fetchOne(
            db, sql: "SELECT maxConnections, expiresAt, accountStatus FROM playlist WHERE id = ?",
            arguments: [pid.uuidString]))
        #expect(row["maxConnections"] as Int? == nil)
        #expect(row["expiresAt"] as Double? == nil)
        #expect(row["accountStatus"] as String? == nil)
        let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        #expect(indexes.isSuperset(of: ["movie_title", "series_title"]))
        #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1", "v2"])
    }

    let playlists = try store.playlists()
    #expect(playlists.map(\.id) == [pid])
    #expect(playlists.first?.name == "Gammal")
    #expect(playlists.first?.lastImportedAt == Date(timeIntervalSince1970: 2000))
    let info = try store.accountInfo(playlistID: pid)
    #expect(info.maxConnections == nil && info.expiresAt == nil && info.status == nil)
    let movie = try #require(try store.movie(playlistID: pid, providerID: "m1"))
    #expect(movie.title == "Ett")
    #expect(movie.year == 1999)
    #expect(movie.locator == .xtream(kind: .movie, streamID: "m1", container: "mkv"))
    #expect(try store.series(playlistID: pid, providerID: "s1")?.title == "Serie")
    let episodes = try store.episodes(playlistID: pid, seriesProviderID: "s1")
    #expect(episodes.map(\.providerID) == ["e1"])
    #expect(episodes.first?.number == 2)
}
