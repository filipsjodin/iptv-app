import Core
import Discovery
import Foundation
import Library
import Metadata
import Personal
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

/// Modell med en importerad Xtream-spellista (fixtures) och en vald profil. Utan TMDB-nyckel: upptäckten bygger
/// på katalogen ensam.
@MainActor
private func discoveryModel() async throws -> (AppModel, UUID) {
    let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    let id = try #require(m.playlists.first?.id)
    m.enter(playlistID: id)
    try #require(m.activeProfile?.profile.playlistID == id)
    return (m, id)
}

private func movieProgress(_ playlistID: UUID, _ providerID: String, updatedAt: Date) -> WatchProgress {
    WatchProgress(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: providerID),
                  position: 600, duration: 6000, watched: false, updatedAt: updatedAt)
}

@MainActor
struct DiscoveryUITests {
    @Test func homeRowsForProfile() async throws {
        let (m, id) = try await discoveryModel()
        let session = try #require(m.activeProfile)
        let expected = try m.discovery.rows(playlistID: id, profile: session.profile, personal: session.personal,
                                            userState: session.userState, kinds: [.movie, .series]).map(\.0)
        #expect(!expected.isEmpty)

        // Utan tittarhistorik: bara upptäcktens rader, i dess ordning.
        let rows = try await m.homeRows(playlistID: id)
        #expect(rows.map(\.id) == expected)
        #expect(rows.allSatisfy { !$0.title.isEmpty })

        // Med en påbörjad film: Fortsätt titta först, sedan samma rader.
        m.userState.save(movieProgress(id, "101", updatedAt: Date()))
        let withProgress = try await m.homeRows(playlistID: id)
        #expect(withProgress.first?.id == .continueWatching)
        #expect(withProgress.first?.continueItems.map(\.request.key.providerID) == ["101"])
        #expect(withProgress.dropFirst().map(\.id) == expected)
    }

    @Test func homeRowsWithoutProfileAreEmpty() async throws {
        let (m, id) = try await discoveryModel()
        m.switchProfile()
        #expect(try await m.homeRows(playlistID: id).isEmpty)
    }

    @Test func myListAndRatingsFromDetail() async throws {
        let (m, id) = try await discoveryModel()
        let ref = ItemRef(kind: .movie, providerID: "101")
        #expect(!m.isInMyList(ref))
        #expect(m.toggleMyList(ref))
        #expect(m.isInMyList(ref))
        #expect(m.activeProfile?.personal.myList() == [ref])

        // Hem-raderna läser signalerna vid varje anrop: Min lista syns direkt nästa gång.
        let rows = try await m.homeRows(playlistID: id)
        let myList = try #require(rows.first { $0.id == .myList })
        #expect(myList.titles.map(\.providerID) == ["101"])

        #expect(m.rating(ref) == nil)
        m.toggleRating(.up, for: ref)
        #expect(m.rating(ref) == .up)
        #expect(m.activeProfile?.personal.rating(ref) == .up)
        m.toggleRating(.down, for: ref)
        #expect(m.rating(ref) == .down)
        // Samma knapp igen tar bort betyget.
        m.toggleRating(.down, for: ref)
        #expect(m.rating(ref) == nil)

        #expect(!m.toggleMyList(ref))
        #expect(!m.isInMyList(ref))
        let after = try await m.homeRows(playlistID: id)
        #expect(!after.contains { $0.id == .myList })
    }

    @Test func myListAndRatingsAreNoOpsWithoutProfile() async throws {
        let (m, _) = try await discoveryModel()
        let ref = ItemRef(kind: .movie, providerID: "101")
        m.switchProfile()
        #expect(!m.toggleMyList(ref))
        m.toggleRating(.up, for: ref)
        #expect(!m.isInMyList(ref))
        #expect(m.rating(ref) == nil)
    }

    @Test func continueWatchingFiltersBeforeLimit() async throws {
        let (m, id) = try await discoveryModel()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Tre filmer (äldst) och 25 serier (nyare): utan filter före gränsen skulle filmerna trängas ut.
        for (i, movie) in ["101", "102", "103"].enumerated() {
            m.userState.save(movieProgress(id, movie, updatedAt: base.addingTimeInterval(Double(i))))
        }
        for i in 0..<25 {
            let key = ProgressKey(playlistID: id, kind: .series, providerID: "e\(i)", seriesProviderID: "s\(i)")
            m.userState.save(WatchProgress(key: key, position: 600, duration: 3000, watched: false,
                                           updatedAt: base.addingTimeInterval(1000 + Double(i))))
        }
        let movies = await m.continueWatching(playlistID: id, kind: .movie)
        #expect(movies.map(\.request.key.providerID) == ["103", "102", "101"])
        #expect(AppModel.continueWatchingLimit == 20)
        #expect(AppModel.continueWatchingEntries(m.userState, playlistID: id, kind: .movie).count == 3)
        #expect(AppModel.continueWatchingEntries(m.userState, playlistID: id, kind: .series).count == 20)
        #expect(AppModel.continueWatchingEntries(m.userState, playlistID: id, kind: nil).count == 20)
    }

    @Test func detailFallsBackToProviderData() async throws {
        let (m, id) = try await discoveryModel()
        let movie = try #require(try m.store.movie(playlistID: id, providerID: "101"))
        let detail = try #require(await m.titleDetail(kind: .movie, providerID: "101", playlistID: id))
        #expect(detail.title == movie.title)
        #expect(detail.year == movie.year)
        #expect(detail.posterURL == movie.posterURL)
        #expect(!detail.hasMetadata)
        #expect(detail.overview == nil && detail.cast.isEmpty && detail.directors.isEmpty && detail.genres.isEmpty)
        #expect(detail.ratings.isEmpty)

        let series = try #require(try m.store.series(playlistID: id, providerID: "5"))
        let seriesDetail = try #require(await m.titleDetail(kind: .series, providerID: "5", playlistID: id))
        #expect(seriesDetail.title == series.title)
        #expect(seriesDetail.posterURL == series.posterURL)

        #expect(await m.titleDetail(kind: .movie, providerID: "finns-inte", playlistID: id) == nil)
        #expect(await m.titleDetail(kind: .live, providerID: "101", playlistID: id) == nil)
        // Liknande titlar och personlistor utan metadata: tomma, ingen krasch.
        _ = await m.similarTitles(kind: .movie, providerID: "101", playlistID: id)
        #expect(await m.titles(withPerson: 42, playlistID: id).isEmpty)
    }

    @Test func detailPrefersTMDBMetadata() {
        let metadata = TitleMetadata(
            tmdbID: 9, kind: .movie, title: "TMDB-titel", overview: "Handling.", year: 2020,
            genres: [Genre(id: 18, name: "Drama")], voteAverage: 7.26, posterPath: "/p.jpg",
            cast: [Person(id: 1, name: "Skådis", character: "Roll")], directors: [Person(id: 2, name: "Regi")],
            certification: "11", language: "sv-SE", imdbRating: 7.8, rottenTomatoes: 93)
        let provider = URL(string: "http://example.invalid/p.jpg")
        let withOMDb = TitleDetail.make(kind: .movie, providerID: "1", title: "Leverantör", year: 2019,
                                        posterURL: provider, metadata: metadata, showExternalRatings: true)
        #expect(withOMDb.title == "Leverantör")
        #expect(withOMDb.year == 2019)
        #expect(withOMDb.posterURL == TMDBImage.url(path: "/p.jpg", size: .w342))
        #expect(withOMDb.overview == "Handling.")
        #expect(withOMDb.genres == ["Drama"])
        #expect(withOMDb.certification == "11")
        #expect(withOMDb.cast == [PersonCredit(id: 1, name: "Skådis", role: "Roll")])
        #expect(withOMDb.directors == [PersonCredit(id: 2, name: "Regi", role: nil)])
        #expect(withOMDb.ratings == [TitleRating(source: "TMDB", value: "7.3"),
                                     TitleRating(source: "IMDb", value: "7.8"),
                                     TitleRating(source: "Rotten Tomatoes", value: "93%")])

        // Utan OMDb-nyckel visas bara TMDB:s betyg.
        let tmdbOnly = TitleDetail.make(kind: .movie, providerID: "1", title: "Leverantör", year: nil,
                                        posterURL: provider, metadata: metadata, showExternalRatings: false)
        #expect(tmdbOnly.ratings.map(\.source) == ["TMDB"])
        #expect(tmdbOnly.year == 2020)

        // Metadata utan affisch: leverantörens affisch.
        var noPoster = metadata
        noPoster.posterPath = nil
        #expect(TitleDetail.make(kind: .movie, providerID: "1", title: "L", year: nil, posterURL: provider,
                                 metadata: noPoster, showExternalRatings: false).posterURL == provider)
    }

    @Test func keysAreReadFromInfoPlistWithMissingRules() {
        #expect(AppModel.usableToken(nil) == nil)
        #expect(AppModel.usableToken("  ") == nil)
        #expect(AppModel.usableToken("$(OMDB_API_KEY)") == nil)
        #expect(AppModel.usableToken("abc") == "abc")
        let m = AppModel(store: LibraryStore(db: try! .inMemory()), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         omdbKey: "$(OMDB_API_KEY)")
        #expect(!m.omdbConfigured)
        let n = AppModel(store: LibraryStore(db: try! .inMemory()), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         omdbKey: "key")
        #expect(n.omdbConfigured)
    }
}
