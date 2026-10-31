import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Kör alla migreringar på `writer`. Internt (inte privat) så att migreringstester kan öppna en äldre databas.
    init(_ writer: any DatabaseWriter) throws {
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
        // TMDB-metadata. `tmdbTitle`, `titleGenre` och `tmdbList` är globala (delas av alla spellistor);
        // `tmdbMatch` hör till spellistan men ligger utanför katalogtabellerna och överlever `replaceCatalog`.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE tmdbTitle (
                    kind TEXT,
                    tmdbID INTEGER,
                    language TEXT,
                    json TEXT NOT NULL,
                    fetchedAt REAL NOT NULL,
                    PRIMARY KEY (kind, tmdbID)
                );

                CREATE TABLE tmdbMatch (
                    playlistID TEXT REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT,
                    providerID TEXT,
                    tmdbID INTEGER,
                    confidence REAL NOT NULL,
                    attemptedAt REAL NOT NULL,
                    PRIMARY KEY (playlistID, kind, providerID)
                );

                CREATE TABLE titleGenre (
                    kind TEXT,
                    tmdbID INTEGER,
                    genreID INTEGER,
                    PRIMARY KEY (kind, tmdbID, genreID)
                );
                CREATE INDEX titleGenre_genre ON titleGenre(genreID);

                CREATE TABLE tmdbList (
                    name TEXT PRIMARY KEY,
                    ids TEXT NOT NULL,
                    fetchedAt REAL NOT NULL
                );
                """)
        }
        // Index för hyllfrågorna (genre- och id-styrda, delindex bara över rader med id) och för
        // berikningsordningen (nyast tillagda först).
        m.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE INDEX movie_tmdb ON movie(playlistID, tmdbID) WHERE tmdbID IS NOT NULL;
                CREATE INDEX series_tmdb ON series(playlistID, tmdbID) WHERE tmdbID IS NOT NULL;
                CREATE INDEX tmdbMatch_tmdb ON tmdbMatch(playlistID, kind, tmdbID) WHERE tmdbID IS NOT NULL;
                CREATE INDEX titleGenre_genre_cover ON titleGenre(genreID, kind, tmdbID);
                CREATE INDEX movie_added ON movie(playlistID, addedAt);
                CREATE INDEX series_added ON series(playlistID, addedAt);
                """)
        }
        // Avsnittens stillbild, beskrivning och längd. `detailsFetched` är 0 för rader som lagrats före den här
        // migreringen (eller aldrig hämtats med uppgifter) och 1 när de skrivits av en hämtning som kan bära dem; det
        // styr den enstaka omhämtningen (`episodesNeedDetails`).
        m.registerMigration("v5") { db in
            try db.execute(sql: """
                ALTER TABLE episode ADD COLUMN stillURL TEXT;
                ALTER TABLE episode ADD COLUMN overview TEXT;
                ALTER TABLE episode ADD COLUMN durationSeconds INTEGER;
                ALTER TABLE episode ADD COLUMN detailsFetched INTEGER NOT NULL DEFAULT 0;
                """)
        }
        // Tablå (EPG). Rader hör till spellistan och försvinner med den (ON DELETE CASCADE). `end > start` hindrar
        // ogiltiga program; `channelSplit` är den manuella uppdelningen av kanalgrupper per leverantörs-id.
        m.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE epgProgram (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    channelID TEXT NOT NULL,
                    start REAL NOT NULL,
                    "end" REAL NOT NULL CHECK ("end" > start),
                    title TEXT NOT NULL,
                    summary TEXT
                );
                CREATE INDEX epgProgram_channel ON epgProgram(playlistID, channelID, start);

                -- Mellanlagring för en pågående hämtning; flyttas in i epgProgram av commitStaging.
                CREATE TABLE epgProgramStaging (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    channelID TEXT NOT NULL,
                    start REAL NOT NULL,
                    "end" REAL NOT NULL CHECK ("end" > start),
                    title TEXT NOT NULL,
                    summary TEXT
                );
                CREATE INDEX epgProgramStaging_playlist ON epgProgramStaging(playlistID);

                CREATE TABLE epgMeta (
                    playlistID TEXT NOT NULL PRIMARY KEY REFERENCES playlist(id) ON DELETE CASCADE,
                    fetchedAt REAL NOT NULL
                );

                CREATE TABLE channelSplit (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    providerID TEXT NOT NULL,
                    PRIMARY KEY (playlistID, providerID)
                );

                -- Importens koppling kanalgrupp -> XMLTV-kanal (id- och namnmatchning), sparad när importen slutförs.
                CREATE TABLE epgChannelMap (
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    groupID TEXT NOT NULL,
                    xmltvID TEXT NOT NULL,
                    PRIMARY KEY (playlistID, groupID)
                );
                """)
        }
        // Undertexter (fas 5). Rader hör till spellistan och försvinner med den (ON DELETE CASCADE); filerna städas av
        // SubtitleStore.purgeOrphans(). `path` är relativ mot undertextkatalogen. `profileID` saknar främmande nyckel
        // (profiler lagras inte i databasen).
        m.registerMigration("v7") { db in
            try db.execute(sql: """
                CREATE TABLE subtitleFile (
                    profileID TEXT NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    providerID TEXT NOT NULL,
                    fileID INTEGER NOT NULL,
                    language TEXT NOT NULL,
                    release TEXT NOT NULL,
                    addedAt REAL NOT NULL,
                    path TEXT NOT NULL,
                    PRIMARY KEY (profileID, playlistID, kind, providerID, fileID)
                );

                CREATE TABLE subtitleOffset (
                    profileID TEXT NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    providerID TEXT NOT NULL,
                    offsetMs INTEGER NOT NULL,
                    PRIMARY KEY (profileID, playlistID, kind, providerID)
                );

                CREATE TABLE titleTechInfo (
                    profileID TEXT NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    providerID TEXT NOT NULL,
                    json TEXT NOT NULL,
                    PRIMARY KEY (profileID, playlistID, kind, providerID)
                );
                """)
        }
        // Nedladdningar: ögonblicksbilder utan FK mot movie/episode (katalogersättning får inte radera dem).
        m.registerMigration("v8") { db in
            try db.execute(sql: """
                CREATE TABLE download (
                    profileID TEXT NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    providerID TEXT NOT NULL,
                    snapshotJSON TEXT NOT NULL,
                    state TEXT NOT NULL,
                    progress REAL NOT NULL DEFAULT 0,
                    bytesWritten INTEGER NOT NULL DEFAULT 0,
                    relativePath TEXT,
                    addedAt REAL NOT NULL,
                    PRIMARY KEY (profileID, playlistID, kind, providerID)
                );
                CREATE INDEX download_profile ON download (profileID, addedAt);
                """)
        }
        return m
    }
}
