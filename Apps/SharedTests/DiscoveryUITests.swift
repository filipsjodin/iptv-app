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

    // MARK: - Barnprofil

    /// Film 101 (leverantörens TMDB-id 12345) är barntillåten (7 år), 103 är för vuxna (18 år, matchad mot 999),
    /// 102 saknar åldersgräns. 101 och 103 delar genre och skådespelare.
    private func seedAges(_ m: AppModel, _ id: UUID) throws {
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm",
                                                       genres: [Genre(id: 16, name: "Animerat")],
                                                       cast: [Person(id: 500, name: "Skådis")], ageLimit: 7,
                                                       language: "sv-SE"), now: Date())
        try m.metadataStore.saveMatch(playlistID: id, kind: .movie, providerID: "103", tmdbID: 999, confidence: 1,
                                      now: Date())
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 999, kind: .movie, title: "Vuxenfilm",
                                                       genres: [Genre(id: 16, name: "Animerat")],
                                                       cast: [Person(id: 500, name: "Skådis")], ageLimit: 18,
                                                       language: "sv-SE"), now: Date())
        m.discovery.invalidate(playlistID: id)
    }

    @MainActor
    private func kidsModel() async throws -> (AppModel, UUID) {
        let (m, id) = try await discoveryModel()
        try seedAges(m, id)
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: kid, pin: nil)
        try #require(m.activeProfile?.profile.isKids == true)
        return (m, id)
    }

    @Test func kidsSeeNoCategoryListingOnlyAgeFilteredRows() async throws {
        let (adult, adultID) = try await discoveryModel()
        guard case let .categories(categories) = try await adult.catalogListing(playlistID: adultID, kind: .movie)
        else { Issue.record("vuxna ska se kategorier"); return }
        #expect(!categories.isEmpty)

        let (m, id) = try await kidsModel()
        for kind in [ContentKind.movie, .series] {
            guard case let .kids(rows) = try await m.catalogListing(playlistID: id, kind: kind) else {
                Issue.record("barnprofilen får aldrig se kategorier eller Alla")
                return
            }
            let shown = Set(rows.flatMap(\.titles).map(\.providerID))
            #expect(shown.isSubset(of: ["101"]))
            if kind == .movie { #expect(shown == ["101"]) }
        }
        let home = try await m.homeRows(playlistID: id)
        #expect(Set(home.flatMap(\.titles).map(\.providerID)) == ["101"])
    }

    @Test func kidsDetailAndPlaybackDeniedForAdultOrUnratedTitles() async throws {
        let (m, id) = try await kidsModel()
        #expect(await m.titleDetail(kind: .movie, providerID: "101", playlistID: id) != nil)
        #expect(await m.titleDetail(kind: .movie, providerID: "103", playlistID: id) == nil)   // 18 år
        #expect(await m.titleDetail(kind: .movie, providerID: "102", playlistID: id) == nil)   // okänd ålder
        #expect(await m.titleDetail(kind: .series, providerID: "5", playlistID: id) == nil)
        #expect(await m.canOpenTitle(kind: .movie, providerID: "101", playlistID: id))
        #expect(await !m.canOpenTitle(kind: .movie, providerID: "103", playlistID: id))

        _ = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil, playlistID: id)
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.playbackRequest(kind: .movie, providerID: "103", seriesProviderID: nil, playlistID: id)
        }
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.playbackRequest(kind: .movie, providerID: "102", seriesProviderID: nil, playlistID: id)
        }
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.playbackRequest(kind: .series, providerID: "501", seriesProviderID: "5", playlistID: id)
        }
        await #expect(throws: PlaybackLookupError.notAllowed) {
            try await m.playbackRequest(kind: .live, providerID: "1", seriesProviderID: nil, playlistID: id)
        }
    }

    @Test func kidsContinueWatchingIsAgeFiltered() async throws {
        let (m, id) = try await kidsModel()
        let base = Date()
        for (i, movie) in ["101", "102", "103"].enumerated() {
            m.userState.save(movieProgress(id, movie, updatedAt: base.addingTimeInterval(Double(i))))
        }
        let episode = ProgressKey(playlistID: id, kind: .series, providerID: "501", seriesProviderID: "5")
        m.userState.save(WatchProgress(key: episode, position: 600, duration: 3000, watched: false,
                                       updatedAt: base.addingTimeInterval(10)))
        #expect(await m.continueWatching(playlistID: id).map(\.request.key.providerID) == ["101"])
        #expect(await m.continueWatching(playlistID: id, kind: .movie).map(\.request.key.providerID) == ["101"])
        #expect(await m.continueWatching(playlistID: id, kind: .series).isEmpty)
    }

    @Test func withoutProfileDiscoveryFailsClosed() async throws {
        let (m, id) = try await discoveryModel()
        try seedAges(m, id)
        // Vuxenprofil: båda filmerna med skådespelaren, och den andra som liknande titel.
        #expect(Set(await m.titles(withPerson: 500, playlistID: id).map(\.providerID)) == ["101", "103"])
        #expect(await m.similarTitles(kind: .movie, providerID: "101", playlistID: id).map(\.providerID)
            .contains("103"))

        m.switchProfile()
        #expect(m.kidsRestricted)
        #expect(await m.titles(withPerson: 500, playlistID: id).map(\.providerID) == ["101"])
        #expect(!(await m.similarTitles(kind: .movie, providerID: "101", playlistID: id).map(\.providerID)
            .contains("103")))
        #expect(await m.titleDetail(kind: .movie, providerID: "103", playlistID: id) == nil)
        guard case let .kids(rows) = try await m.catalogListing(playlistID: id, kind: .movie) else {
            Issue.record("utan profil: inga kategorier")
            return
        }
        #expect(rows.isEmpty)
    }

    // MARK: - Detaljsidan (fas 3b, uppgift 6)

    @Test func continueButtonShowsEpisodeAndRemainingTime() {
        // 31 min 5 s kvar avrundas uppåt till 32 min.
        #expect(DetailPresentation.remaining(seconds: 31 * 60 + 5) == .minutes(32))
        #expect(DetailPresentation.remaining(seconds: 60) == .minutes(1))
        #expect(DetailPresentation.remaining(seconds: 61) == .minutes(2))
        #expect(DetailPresentation.remaining(seconds: 59 * 60) == .minutes(59))
        // Från en timme: timmar och minuter.
        #expect(DetailPresentation.remaining(seconds: 65 * 60) == .hoursMinutes(1, 5))
        #expect(DetailPresentation.remaining(seconds: 3600) == .hoursMinutes(1, 0))
        #expect(DetailPresentation.remaining(seconds: 0) == nil)
        #expect(DetailPresentation.remaining(seconds: -5) == nil)
        #expect(DetailPresentation.remaining(seconds: .nan) == nil)

        let label = DetailPresentation.continueLabel(episode: "S2:E4", remaining: 31 * 60 + 5)
        #expect(label.contains("S2:E4"))
        #expect(label.contains("32"))
        let long = DetailPresentation.continueLabel(episode: "S2:E4", remaining: 65 * 60)
        #expect(long.contains("1") && long.contains("5"))
        // Film (inget avsnitt) och okänd längd.
        #expect(DetailPresentation.continueLabel(episode: nil, remaining: 31 * 60 + 5).contains("32"))
        let noTime = DetailPresentation.continueLabel(episode: "S2:E4", remaining: nil)
        #expect(noTime.contains("S2:E4") && !noTime.contains("·"))
        #expect(!DetailPresentation.continueLabel(episode: nil, remaining: nil).isEmpty)
    }

    @Test func fromStartResetsResumePosition() async throws {
        let (m, id) = try await discoveryModel()
        m.userState.save(movieProgress(id, "101", updatedAt: Date()))
        let key = ProgressKey(playlistID: id, kind: .movie, providerID: "101")
        let progress = m.userState.progress(for: key)
        #expect(DetailPresentation.startPosition(progress: progress, fromStart: false) == 600)
        #expect(DetailPresentation.startPosition(progress: progress, fromStart: true) == 0)
        #expect(DetailPresentation.startPosition(progress: nil, fromStart: false) == nil)

        // Samma väg som knapparna: Fortsätt tar sparad position, Från början nollar den.
        let resumed = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                  playlistID: id, startFromBeginning: false)
        #expect(resumed.startAt == 600)
        let fresh = try await m.playbackRequest(kind: .movie, providerID: "101", seriesProviderID: nil,
                                                playlistID: id, startFromBeginning: true)
        #expect(fresh.startAt == 0)
    }

    @Test func ratingToggleCyclesUpDownNone() async throws {
        var rating: Rating?
        rating = DetailPresentation.rating(afterTapping: .up, current: rating)
        #expect(rating == .up)
        rating = DetailPresentation.rating(afterTapping: .down, current: rating)
        #expect(rating == .down)
        rating = DetailPresentation.rating(afterTapping: .down, current: rating)
        #expect(rating == nil)
        #expect(DetailPresentation.rating(afterTapping: .up, current: .up) == nil)

        // Modellen följer samma regel.
        let (m, _) = try await discoveryModel()
        let ref = ItemRef(kind: .movie, providerID: "101")
        m.toggleRating(.up, for: ref)
        #expect(m.rating(ref) == .up)
        m.toggleRating(.down, for: ref)
        #expect(m.rating(ref) == .down)
        m.toggleRating(.down, for: ref)
        #expect(m.rating(ref) == nil)
    }

    @Test func similarTitlesDoNotWaitForMetadataFetch() async throws {
        let (m, id) = try await discoveryModel()
        let expected = try #require(try m.store.movie(playlistID: id, providerID: "101"))
        let item = Library.LibraryItem(kind: .movie, providerID: expected.providerID, title: expected.title,
                                       year: expected.year, posterURL: expected.posterURL)
        let loader = TitleExtrasLoader()
        // Metadatahämtningen hänger (en TMDB-förfrågan utan svar); de liknande titlarna ska ändå levereras.
        loader.start(detail: {
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }, similar: { [item] })
        var waited = 0
        while loader.similar.isEmpty, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(loader.similar.map(\.providerID) == [item.providerID])
        #expect(loader.detail == nil)
        #expect(loader.similarLoaded)
        loader.cancel()
    }

    @Test func previewSettingsPersistPerProfile() async throws {
        let defaults = freshDefaults()
        let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        let id = try #require(m.playlists.first?.id)
        m.enter(playlistID: id)
        let first = try #require(m.activeProfile?.profile)
        #expect(m.settings.previewsEnabled && m.settings.previewSoundEnabled)

        m.settings.previewsEnabled = false
        let second = try m.addProfile(playlistID: id, name: "Två", avatar: "star.fill")
        try await m.select(profile: second, pin: nil)
        // Den andra profilen påverkas inte.
        #expect(m.settings.previewsEnabled)
        m.settings.previewSoundEnabled = false

        let savedFirst = PlaybackSettings.load(from: defaults, key: ProfileKeys.settings(first.id))
        #expect(!savedFirst.previewsEnabled && savedFirst.previewSoundEnabled)
        let savedSecond = PlaybackSettings.load(from: defaults, key: ProfileKeys.settings(second.id))
        #expect(savedSecond.previewsEnabled && !savedSecond.previewSoundEnabled)
    }

    @Test func detailWithoutBackdropOrLogoFallsBackWithoutBlankAreas() async throws {
        let (m, id) = try await discoveryModel()
        let movie = try #require(try m.store.movie(playlistID: id, providerID: "101"))
        let item = Library.LibraryItem(kind: .movie, providerID: movie.providerID, title: movie.title,
                                       year: movie.year, posterURL: movie.posterURL)
        // Ingen hero alls (t.ex. innan den hunnit läsas): leverantörens titel och affisch.
        let fallback = DetailPresentation.displayHero(nil, item: item, container: movie.container)
        #expect(fallback.title == movie.title)
        #expect(fallback.backdropURL == nil && fallback.logoURL == nil)
        #expect(fallback.posterURL == movie.posterURL)
        #expect(HeroBackdrop.imageURL(for: fallback) == movie.posterURL)
        #expect(fallback.overview == nil && fallback.ratings.isEmpty)

        // En hero utan backdrop och logga används som den är; bilden blir affischen.
        let bare = AppModel.makeHero(item: item, metadata: nil, container: nil, showExternalRatings: false)
        #expect(DetailPresentation.displayHero(bare, item: item, container: nil) == bare)
        #expect(HeroBackdrop.imageURL(for: bare) == movie.posterURL)
    }
}
