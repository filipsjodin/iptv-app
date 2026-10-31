import Core
import Discovery
import Foundation
import GRDB
import Metadata
import Personal
import PlaybackCore
import Testing

@testable import Library

private func generatedCatalog(movies: Int, series: Int, episodes: Int, live: Int) -> ProviderCatalog {
    let words = ["the", "star", "wars", "dune", "fröken", "julie", "night", "river", "king", "last", "dark", "city", "x", "war"]
    func title(_ i: Int) -> String {
        "\(words[i % words.count].capitalized) \(words[(i / 7) % words.count]) \(words[(i / 31) % words.count]) \(i)"
    }
    var c = ProviderCatalog()
    c.movies.reserveCapacity(movies)
    for i in 0..<movies {
        c.movies.append(Movie(providerID: "m\(i)", title: title(i), year: 1950 + i % 75, categoryID: "\(i % 50)",
                              posterURL: URL(string: "http://img.example/m\(i).jpg"), container: "mp4",
                              locator: .xtream(kind: .movie, streamID: "m\(i)", container: "mp4")))
    }
    for i in 0..<series {
        c.series.append(Series(providerID: "s\(i)", title: title(i + 3), year: 1980 + i % 45, categoryID: "\(i % 20)"))
    }
    for i in 0..<episodes {
        c.episodes.append(Episode(providerID: "e\(i)", seriesProviderID: "s\(i % max(series, 1))", season: 1, number: i,
                                  title: "Ep \(i)", locator: .xtream(kind: .series, streamID: "e\(i)", container: "mkv")))
    }
    for i in 0..<live {
        c.live.append(LiveStream(providerID: "l\(i)", name: "SE: \(title(i + 5)) HD", categoryID: "\(i % 30)",
                                 locator: .xtream(kind: .live, streamID: "l\(i)", container: "ts")))
    }
    return c
}

/// Seriellt: testerna mäter tid och får inte konkurrera om CPU och disk.
@Suite(.serialized) struct LibraryPerformance {
    @Test func import200kAndSearchFast() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try LibraryStore(db: .onDisk(at: url))
        let p = Playlist(name: "Perf", kind: .xtream)
        try s.upsertPlaylist(p)
        let c = generatedCatalog(movies: 120_000, series: 20_000, episodes: 0, live: 60_000)
        let importTime = try ContinuousClock().measure { try s.replaceCatalog(c, playlistID: p.id, now: .now) }
        print("PERF import 200k: \(importTime)")
        #expect(importTime < .seconds(20))
        let refreshTime = try ContinuousClock().measure { try s.replaceCatalog(c, playlistID: p.id, now: .now) }
        print("PERF refresh 200k: \(refreshTime)")
        #expect(refreshTime < .seconds(20))
        for q in ["the", "star wa", "fröken", "x"] {
            var hits = 0
            let t = try ContinuousClock().measure { hits = try s.search(q, playlistID: p.id, limit: 50).count }
            print("PERF search '\(q)': \(t) (\(hits) hits)")
            #expect(hits > 0)
            #expect(t < .milliseconds(100))
        }
    }

    /// Hyllfrågor mot TMDB-data i en spellista med 120 000 filmer: hälften har leverantörens id, hälften en matchning.
    @Test func metadataShelvesFastAt120k() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-meta-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AppDatabase.onDisk(at: url)
        let library = LibraryStore(db: db)
        let store = MetadataStore(db: db)
        let p = Playlist(name: "Perf", kind: .xtream)
        try library.upsertPlaylist(p)
        var c = generatedCatalog(movies: 120_000, series: 0, episodes: 0, live: 0)
        for i in stride(from: 0, to: c.movies.count, by: 2) { c.movies[i].tmdbID = i + 1 }
        try library.replaceCatalog(c, playlistID: p.id, now: .now)

        try db.writer.write { db in
            let match = try db.makeStatement(sql: """
                INSERT INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
                VALUES (?, 'movie', ?, ?, 0.9, 0)
                """)
            let genre = try db.makeStatement(sql: "INSERT INTO titleGenre (kind, tmdbID, genreID) VALUES ('movie', ?, ?)")
            for i in 0..<120_000 {
                if i % 2 == 1 { try match.execute(arguments: [p.id.uuidString, "m\(i)", i + 1]) }
                try genre.execute(arguments: [i + 1, 1])                  // vanlig genre
                if i % 1000 == 0 || i % 1000 == 1 { try genre.execute(arguments: [i + 1, 99]) }   // sällsynt genre
            }
        }

        var shelf: [LibraryItem] = []
        let shelfTime = try ContinuousClock().measure {
            shelf = try store.items(playlistID: p.id, kind: .movie, genreID: 99, limit: 50)
        }
        print("PERF rare-genre shelf 120k: \(shelfTime) (\(shelf.count) items)")
        #expect(shelf.count == 50)
        #expect(shelfTime < .milliseconds(100))

        let ids = (0..<20).map { $0 * 5_999 + 1 }
        var list: [LibraryItem] = []
        let listTime = try ContinuousClock().measure {
            list = try store.items(playlistID: p.id, kind: .movie, tmdbIDs: ids)
        }
        print("PERF 20-id list 120k: \(listTime) (\(list.count) items)")
        #expect(list.map(\.providerID) == ids.map { "m\($0 - 1)" })
        #expect(listTime < .milliseconds(100))
    }

    /// Upptäckt i en spellista med 120 000 filmer där 30 % har metadata (hälften via leverantörens id, hälften via
    /// matchning): kandidatfrågan (utan cache) och Hem-raderna (på cachade kandidater) med några signaler.
    @Test func discoveryCandidatesAndRowsAt120k() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-disc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AppDatabase.onDisk(at: url)
        let library = LibraryStore(db: db)
        let store = MetadataStore(db: db)
        let p = Playlist(name: "Perf", kind: .xtream)
        try library.upsertPlaylist(p)
        var c = generatedCatalog(movies: 120_000, series: 0, episodes: 0, live: 0)
        let withMeta = (0..<c.movies.count).filter { $0 % 10 < 3 }
        for i in c.movies.indices { c.movies[i].addedAt = Date(timeIntervalSince1970: 1_600_000_000 + Double(i)) }
        for i in withMeta where i % 2 == 0 { c.movies[i].tmdbID = i + 1 }
        try library.replaceCatalog(c, playlistID: p.id, now: .now)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.writer.write { db in
            let match = try db.makeStatement(sql: """
                INSERT INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
                VALUES (?, 'movie', ?, ?, 0.9, 0)
                """)
            let title = try db.makeStatement(sql: """
                INSERT INTO tmdbTitle (kind, tmdbID, language, json, fetchedAt) VALUES ('movie', ?, 'sv-SE', ?, 0)
                """)
            let genre = try db.makeStatement(sql: "INSERT INTO titleGenre (kind, tmdbID, genreID) VALUES ('movie', ?, ?)")
            for i in withMeta {
                let id = i + 1
                if i % 2 == 1 { try match.execute(arguments: [p.id.uuidString, "m\(i)", id]) }
                let genres = Array(Set([i % 19, (i / 19) % 19, 30 + i % 3]))
                let m = TitleMetadata(
                    tmdbID: id, kind: .movie, title: "Titel \(i)", originalTitle: "Original \(i)",
                    overview: String(repeating: "Lång beskrivning av filmen. ", count: 12), year: 2000 + i % 25,
                    runtimeMinutes: 110, genres: genres.map { Genre(id: $0, name: "Genre \($0)") }, voteAverage: 7.1,
                    voteCount: 1000, popularity: Double(i % 997), posterPath: "/p\(i).jpg", backdropPath: "/b\(i).jpg",
                    cast: (0..<15).map { Person(id: (i * 15 + $0) % 50_000, name: "Skådespelare \($0)",
                                                 character: "Roll \($0)", profilePath: "/c\($0).jpg") },
                    directors: [Person(id: 100_000 + i % 5_000, name: "Regissör")],
                    keywords: (0..<10).map { "nyckelord \((i + $0) % 400)" }, certification: "15",
                    ageLimit: [0, 7, 11, 15][i % 4], recommendations: (1...20).map { (id + $0 * 37) % 120_000 },
                    similar: (1...20).map { (id + $0 * 53) % 120_000 }, imdbID: "tt\(i)", language: "sv-SE")
                try title.execute(arguments: [id, String(decoding: try encoder.encode(m), as: UTF8.self)])
                for g in genres { try genre.execute(arguments: [id, g]) }
            }
        }
        try store.saveList("trending.movie", ids: withMeta.prefix(50).map { $0 + 1 }, now: .now)

        // Bara SQL-delen (för att se fördelningen mellan fråga och tolkning).
        var sqlRows = 0
        let sqlTime = try ContinuousClock().measure {
            sqlRows = try db.writer.read { db in
                try Row.fetchAll(db, sql: DiscoveryService.candidatesSQL(kind: .movie),
                                 arguments: [p.id.uuidString, "movie"]).count
            }
        }
        print("PERF discovery candidates SQL only 120k: \(sqlTime) (\(sqlRows) rows)")

        let service = DiscoveryService(library: library, metadata: store)
        var candidates: [Candidate] = []
        let candidatesTime = try ContinuousClock().measure {
            candidates = try service.candidates(playlistID: p.id, kind: .movie)
        }
        print("PERF discovery candidates 120k: \(candidatesTime) (\(candidates.count) candidates)")
        #expect(candidates.count == 120_000)
        #expect(candidates.filter { !$0.genres.isEmpty }.count == withMeta.count)
        #expect(candidatesTime < .seconds(1.5))

        let personal = UserDefaultsPersonalStore(defaults: UserDefaults(suiteName: "perf.\(UUID())")!, key: "p")
        let state = InMemoryUserStateStore()
        for i in withMeta.prefix(40) {
            let ref = ItemRef(kind: .movie, providerID: "m\(i)")
            if i % 3 == 0 { _ = personal.toggleMyList(ref) }
            if i % 4 == 0 { personal.setRating(i % 8 == 0 ? .up : .down, for: ref) }
            state.save(WatchProgress(key: ProgressKey(playlistID: p.id, kind: .movie, providerID: "m\(i)"),
                                     position: 95, duration: 100, watched: true, updatedAt: .now))
        }
        for kids in [false, true] {
            let profile = Profile(playlistID: p.id, name: "P", avatar: "star", isKids: kids)
            var rows: [(RowID, [LibraryItem])] = []
            let rowsTime = try ContinuousClock().measure {
                rows = try service.rows(playlistID: p.id, profile: profile, personal: personal, userState: state,
                                        kinds: [.movie, .series])
            }
            print("PERF discovery rows 120k (kids: \(kids)): \(rowsTime) (\(rows.count) rows)")
            #expect(rows.count >= 10)
            #expect(rowsTime < .milliseconds(300))
        }
    }

    /// Fokus→hero i en spellista med 200 000 filmer (Nightly larmar över 100 ms i medel). Mäter databasläsningen
    /// bakom `AppModel.hero` (container ur filmen, TMDB-id via leverantörens id eller matchning, och metadatan),
    /// den enda del av en hero-laddning som kostar något; appens egna typer ligger i apptestbundeln och kan inte
    /// köras i det här paketet. Titlarna sprids över hela katalogen så att läsningarna inte ligger i samma sidor.
    @Test func focusToHeroLatencyAt200k() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-hero-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AppDatabase.onDisk(at: url)
        let library = LibraryStore(db: db)
        let store = MetadataStore(db: db)
        let p = Playlist(name: "Perf", kind: .xtream)
        try library.upsertPlaylist(p)
        let total = 200_000
        var c = generatedCatalog(movies: total, series: 0, episodes: 0, live: 0)
        let withMeta = (0..<total).filter { $0 % 5 == 0 }
        for i in withMeta where i % 2 == 0 { c.movies[i].tmdbID = i + 1 }
        try library.replaceCatalog(c, playlistID: p.id, now: .now)

        let encoder = JSONEncoder()
        try db.writer.write { db in
            let match = try db.makeStatement(sql: """
                INSERT INTO tmdbMatch (playlistID, kind, providerID, tmdbID, confidence, attemptedAt)
                VALUES (?, 'movie', ?, ?, 0.9, 0)
                """)
            let title = try db.makeStatement(sql: """
                INSERT INTO tmdbTitle (kind, tmdbID, language, json, fetchedAt) VALUES ('movie', ?, 'sv-SE', ?, 0)
                """)
            for i in withMeta {
                let id = i + 1
                if i % 2 == 1 { try match.execute(arguments: [p.id.uuidString, "m\(i)", id]) }
                let m = TitleMetadata(
                    tmdbID: id, kind: .movie, title: "Titel \(i)", originalTitle: "Original \(i)",
                    overview: String(repeating: "Lång beskrivning av filmen. ", count: 12), year: 2000 + i % 25,
                    runtimeMinutes: 110, genres: [Genre(id: i % 19, name: "Genre")], voteAverage: 7.1, voteCount: 1000,
                    popularity: 10, posterPath: "/p\(i).jpg", backdropPath: "/b\(i).jpg",
                    cast: (0..<15).map { Person(id: (i * 15 + $0) % 50_000, name: "Skådespelare \($0)",
                                                 character: "Roll \($0)", profilePath: "/c\($0).jpg") },
                    certification: "15", ageLimit: 15, imdbID: "tt\(i)", language: "sv-SE")
                try title.execute(arguments: [id, String(decoding: try encoder.encode(m), as: UTF8.self)])
            }
        }

        // Samma läsning som `AppModel.hero` gör utanför huvudtråden, för 200 spridda titlar (var femte har metadata).
        let providerID = p.id
        func read(_ i: Int) throws -> Bool {
            _ = try library.movie(playlistID: providerID, providerID: "m\(i)")?.container
            guard let id = try store.tmdbID(playlistID: providerID, kind: .movie, providerID: "m\(i)") else {
                return false
            }
            return try store.metadata(kind: .movie, tmdbID: id) != nil
        }
        _ = try read(0)   // värmer upp anslutning och statement-cache
        let sample = (0..<200).map { ($0 * 997) % total }
        var withData = 0
        var durations: [Duration] = []
        for i in sample {
            var found = false
            durations.append(try ContinuousClock().measure { found = try read(i) })
            if found { withData += 1 }
        }
        let average = durations.reduce(.zero, +) / durations.count
        let worst = durations.max() ?? .zero
        print("PERF focus-to-hero 200k: avg \(average), worst \(worst) (\(withData)/\(sample.count) with metadata)")
        #expect(withData > 0)
        #expect(average < .milliseconds(100))
    }
}
