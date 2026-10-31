import Core
import Foundation
import GRDB
import Metadata
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
        #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"])
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

/// En databas från fas 2 (v2) får metadatatabellerna utan dataförlust. Matchningar följer spellistan,
/// titelcachen är global.
@Test func migrationV2ToV3KeepsData() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator.migrate(queue, upTo: "v2")
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO playlist (id, name, kind, createdAt, lastImportedAt, maxConnections, accountStatus)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "Fas2", "xtream", 1000.0, 2000.0, 2, "Active"])
        try db.execute(sql: """
            INSERT INTO movie (playlistID, providerID, title, year, container, tmdbID, locator, firstSeenAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "m1", "Ett", 1999, "mkv", 603,
                             try locatorJSON(.xtream(kind: .movie, streamID: "m1", container: "mkv")), 1.0, 1.0])
    }
    #expect(try queue.read { try $0.tableExists("tmdbTitle") } == false)

    let database = try AppDatabase(queue)
    let library = LibraryStore(db: database)
    let store = MetadataStore(db: database)

    try queue.read { db in
        for table in ["tmdbTitle", "tmdbMatch", "titleGenre", "tmdbList"] {
            #expect(try db.tableExists(table), "saknar \(table)")
        }
        let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        #expect(indexes.contains("titleGenre_genre"))
        #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"])
    }
    #expect(try library.playlists().map(\.name) == ["Fas2"])
    #expect(try library.accountInfo(playlistID: pid).maxConnections == 2)
    let movie = try #require(try library.movie(playlistID: pid, providerID: "m1"))
    #expect(movie.title == "Ett" && movie.tmdbID == 603)
    #expect(try store.tmdbID(playlistID: pid, kind: .movie, providerID: "m1") == 603)

    try store.saveMatch(playlistID: pid, kind: .movie, providerID: "m1", tmdbID: 603, confidence: 1,
                        now: Date(timeIntervalSince1970: 3000))
    try store.saveMetadata(TitleMetadata(tmdbID: 603, kind: .movie, title: "The Matrix",
                                         genres: [Genre(id: 28, name: "Action")], language: "sv-SE"),
                           now: Date(timeIntervalSince1970: 3000))
    try library.deletePlaylist(pid)
    let counts = try queue.read { db in
        try ["tmdbMatch", "tmdbTitle", "titleGenre"].map {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
        }
    }
    #expect(counts == [0, 1, 1])
    #expect(try store.metadata(kind: .movie, tmdbID: 603)?.title == "The Matrix")
}

/// v3 → v4 lägger bara till index; data och matchningar är orörda.
@Test func migrationV3ToV4AddsIndexes() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator.migrate(queue, upTo: "v3")
    try queue.write { db in
        try db.execute(sql: "INSERT INTO playlist (id, name, kind, createdAt) VALUES (?, ?, ?, ?)",
                       arguments: [pid.uuidString, "Fas3", "xtream", 1000.0])
        try db.execute(sql: """
            INSERT INTO movie (playlistID, providerID, title, tmdbID, addedAt, locator, firstSeenAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pid.uuidString, "m1", "Ett", 603, 50.0,
                             try locatorJSON(.xtream(kind: .movie, streamID: "m1", container: "mkv")), 1.0, 1.0])
        try db.execute(sql: """
            INSERT INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
            VALUES (?, 'movie', 'm2', 77, 0.9, 10.0)
            """, arguments: [pid.uuidString])
        try db.execute(sql: "INSERT INTO titleGenre (kind, tmdbID, genreID) VALUES ('movie', 603, 28)")
    }
    let database = try AppDatabase(queue)
    let indexes = try queue.read { db in
        Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
    }
    #expect(indexes.isSuperset(of: ["movie_tmdb", "series_tmdb", "tmdbMatch_tmdb", "titleGenre_genre_cover",
                                    "movie_added", "series_added", "titleGenre_genre"]))
    #expect(try queue.read { try AppDatabase.migrator.appliedMigrations($0) } == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"])
    let store = MetadataStore(db: database)
    #expect(try store.match(playlistID: pid, kind: .movie, providerID: "m2")?.tmdbID == 77)
    #expect(try store.items(playlistID: pid, kind: .movie, genreID: 28, limit: 10).map(\.providerID) == ["m1"])
}

/// En databas från v4 med avsnitt får de nya kolumnerna utan dataförlust; raderna räknas som ännu inte omhämtade.
@Test func migrationV4ToV5KeepsEpisodesAndAddsDetailColumns() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator.migrate(queue, upTo: "v4")
    try queue.write { db in
        try db.execute(sql: "INSERT INTO playlist (id, name, kind, createdAt, lastImportedAt) VALUES (?, ?, ?, ?, ?)",
                       arguments: [pid.uuidString, "Fas3", "xtream", 1000.0, 2000.0])
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
    let store = LibraryStore(db: try AppDatabase(queue))
    try queue.read { db in
        let columns = Set(try db.columns(in: "episode").map(\.name))
        #expect(columns.isSuperset(of: ["stillURL", "overview", "durationSeconds", "detailsFetched"]))
        #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"])
    }
    let episodes = try store.episodes(playlistID: pid, seriesProviderID: "s1")
    #expect(episodes.map(\.providerID) == ["e1"])
    #expect(episodes.first?.title == "Avsnitt")
    #expect(episodes.first?.stillURL == nil && episodes.first?.overview == nil && episodes.first?.durationSeconds == nil)
    #expect(try store.episodesNeedDetails(playlistID: pid, seriesProviderID: "s1"))
}
