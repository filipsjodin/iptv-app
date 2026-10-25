import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    private init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE playlist (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    lastImportedAt REAL
                );

                CREATE TABLE category (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    providerID TEXT NOT NULL,
                    name TEXT NOT NULL,
                    sortIndex INTEGER NOT NULL,
                    PRIMARY KEY (playlistID, kind, providerID)
                );

                CREATE TABLE movie (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    providerID TEXT NOT NULL CHECK (providerID <> ''),
                    title TEXT NOT NULL,
                    year INTEGER,
                    categoryID TEXT,
                    posterURL TEXT,
                    container TEXT,
                    tmdbID INTEGER,
                    rating REAL,
                    addedAt REAL,
                    locator TEXT NOT NULL,
                    firstSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    UNIQUE (playlistID, providerID)
                );
                CREATE INDEX movie_category ON movie(playlistID, categoryID);

                CREATE TABLE series (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    providerID TEXT NOT NULL CHECK (providerID <> ''),
                    title TEXT NOT NULL,
                    year INTEGER,
                    categoryID TEXT,
                    posterURL TEXT,
                    tmdbID INTEGER,
                    rating REAL,
                    addedAt REAL,
                    firstSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    UNIQUE (playlistID, providerID)
                );
                CREATE INDEX series_category ON series(playlistID, categoryID);

                CREATE TABLE episode (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    providerID TEXT NOT NULL CHECK (providerID <> ''),
                    seriesProviderID TEXT NOT NULL,
                    season INTEGER NOT NULL,
                    number INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    container TEXT,
                    locator TEXT NOT NULL,
                    firstSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    UNIQUE (playlistID, providerID)
                );
                CREATE INDEX episode_series ON episode(playlistID, seriesProviderID);

                CREATE TABLE liveStream (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    providerID TEXT NOT NULL CHECK (providerID <> ''),
                    name TEXT NOT NULL,
                    categoryID TEXT,
                    logoURL TEXT,
                    epgChannelID TEXT,
                    locator TEXT NOT NULL,
                    firstSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    UNIQUE (playlistID, providerID)
                );
                CREATE INDEX liveStream_category ON liveStream(playlistID, categoryID);

                CREATE VIRTUAL TABLE searchIndex USING fts5(
                    title,
                    kind UNINDEXED,
                    playlistID UNINDEXED,
                    providerID UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE playlist ADD COLUMN maxConnections INTEGER;
                ALTER TABLE playlist ADD COLUMN expiresAt REAL;
                ALTER TABLE playlist ADD COLUMN accountStatus TEXT;
                CREATE INDEX movie_title ON movie(playlistID, title COLLATE NOCASE);
                CREATE INDEX series_title ON series(playlistID, title COLLATE NOCASE);
                """)
        }
        return m
    }
}
