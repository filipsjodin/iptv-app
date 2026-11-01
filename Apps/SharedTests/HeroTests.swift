import Core
import Foundation
import GRDB
import Library
import Metadata
import Providers
import ProvidersTestSupport
import Testing
import UIKit
@testable import IPTVApp

/// UIKit (importerat för UIImage) har ett eget LibraryItem; biblioteksmodulens vinner här.
private typealias LibraryItem = Library.LibraryItem

/// Modell med en importerad Xtream-spellista (fixtures) och en vald vuxenprofil. Utan TMDB-nyckel.
@MainActor
private func heroModel() async throws -> (AppModel, UUID) {
    let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    let id = try #require(m.playlists.first?.id)
    m.enter(playlistID: id)
    try #require(m.activeProfile?.profile.playlistID == id)
    return (m, id)
}

@MainActor
private func movieItem(_ m: AppModel, _ id: UUID, _ providerID: String) throws -> LibraryItem {
    let movie = try #require(try m.store.movie(playlistID: id, providerID: providerID))
    return LibraryItem(kind: .movie, providerID: providerID, title: movie.title, year: movie.year,
                       posterURL: movie.posterURL)
}

/// Film 101 (leverantörens TMDB-id 12345) är barntillåten (7 år), 103 är för vuxna (18 år, matchad mot 999) och 102
/// saknar åldersgräns.
@MainActor
private func seedAges(_ m: AppModel, _ id: UUID) throws {
    try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm", ageLimit: 7,
                                                   language: "sv-SE"), now: Date())
    try m.metadataStore.saveMatch(playlistID: id, kind: .movie, providerID: "103", tmdbID: 999, confidence: 1,
                                  now: Date())
    try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 999, kind: .movie, title: "Vuxenfilm", ageLimit: 18,
                                                   language: "sv-SE"), now: Date())
    m.discovery.invalidate(playlistID: id)
}

@MainActor
private func selectKids(_ m: AppModel, _ id: UUID) async throws {
    let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
    try await m.select(profile: kid, pin: nil)
    try #require(m.activeProfile?.profile.isKids == true)
}

@MainActor
struct HeroTests {
    @Test func heroFallsBackToProviderData() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        let hero = try #require(await m.hero(for: item, playlistID: id))
        #expect(hero.kind == .movie && hero.providerID == "101")
        #expect(hero.title == item.title)
        #expect(hero.year == item.year)
        #expect(hero.posterURL == item.posterURL)
        #expect(hero.backdropURL == nil && hero.logoURL == nil)
        #expect(hero.overview == nil && hero.runtimeMinutes == nil && hero.certification == nil)
        #expect(hero.ratings.isEmpty)
        #expect(hero.badges == QualityBadges.parse(title: item.title, containerExtension: nil))

        let series = try #require(try m.store.series(playlistID: id, providerID: "5"))
        let seriesItem = LibraryItem(kind: .series, providerID: "5", title: series.title, year: series.year,
                                     posterURL: series.posterURL)
        #expect(await m.hero(for: seriesItem, playlistID: id)?.title == series.title)

        // Live har ingen hero.
        let live = LibraryItem(kind: .live, providerID: "1", title: "Kanal", year: nil, posterURL: nil)
        #expect(await m.hero(for: live, playlistID: id) == nil)
    }

    @Test func heroUsesMetadataImagesAndDetails() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "TMDB-titel", overview: "  Handling.  ", year: 2020,
                          runtimeMinutes: 118, voteAverage: 7.26, posterPath: "/p.jpg", backdropPath: "/b.jpg",
                          logoPath: "/l.png", certification: "11", language: "sv-SE"), now: Date())
        let hero = try #require(await m.hero(for: item, playlistID: id))
        #expect(hero.title == item.title)   // leverantörens titel vinner, som på detaljsidan
        #expect(hero.backdropURL == TMDBImage.url(path: "/b.jpg", size: ArtworkKind.backdrop.tmdbSize))
        #expect(hero.backdropURL?.absoluteString.contains("/w1280/") == true)
        #expect(hero.logoURL == TMDBImage.url(path: "/l.png", size: ArtworkKind.logo.tmdbSize))
        #expect(hero.posterURL == TMDBImage.url(path: "/p.jpg", size: ArtworkKind.poster.tmdbSize))
        #expect(hero.overview == "Handling.")
        #expect(hero.runtimeMinutes == 118)
        #expect(hero.certification == "11")
        #expect(hero.ratings == [TitleRating(source: "TMDB", value: "7.3")])

        // Metadata utan backdrop och logga: ändå en hero, med reservvärden.
        let other = try movieItem(m, id, "103")
        try m.metadataStore.saveMatch(playlistID: id, kind: .movie, providerID: "103", tmdbID: 999, confidence: 1,
                                      now: Date())
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 999, kind: .movie, title: "X", language: "sv-SE"),
                                         now: Date())
        let bare = try #require(await m.hero(for: other, playlistID: id))
        #expect(bare.backdropURL == nil && bare.logoURL == nil)
        #expect(bare.posterURL == other.posterURL)
    }

    @Test func heroDeniedForKidsWhenUnrated() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        try await selectKids(m, id)
        #expect(await m.hero(for: try movieItem(m, id, "101"), playlistID: id)?.providerID == "101")   // 7 år
        #expect(await m.hero(for: try movieItem(m, id, "103"), playlistID: id) == nil)   // 18 år
        #expect(await m.hero(for: try movieItem(m, id, "102"), playlistID: id) == nil)   // okänd ålder
        let series = try #require(try m.store.series(playlistID: id, providerID: "5"))
        let seriesItem = LibraryItem(kind: .series, providerID: "5", title: series.title, year: series.year,
                                     posterURL: series.posterURL)
        #expect(await m.hero(for: seriesItem, playlistID: id) == nil)

        // Utan vald profil är barnläget på (stängt som standard).
        m.switchProfile()
        #expect(await m.hero(for: try movieItem(m, id, "102"), playlistID: id) == nil)
    }

    @Test func heroCachedForOneProfileIsNeverServedToAnother() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        let adult = try #require(m.activeProfile?.profile)
        let adultOnly = try movieItem(m, id, "103")
        let unrated = try movieItem(m, id, "102")
        #expect(await m.hero(for: adultOnly, playlistID: id) != nil)
        #expect(await m.hero(for: unrated, playlistID: id) != nil)
        // Cachad hero för vuxenprofilen (andra anropet kommer ur cachen)...
        #expect(await m.hero(for: adultOnly, playlistID: id) != nil)

        // ...får inte lämnas ut till barnprofilen.
        try await selectKids(m, id)
        #expect(await m.hero(for: adultOnly, playlistID: id) == nil)
        #expect(await m.hero(for: unrated, playlistID: id) == nil)

        // Tillbaka till vuxenprofilen: heron finns igen.
        try await m.select(profile: adult, pin: nil)
        #expect(await m.hero(for: adultOnly, playlistID: id) != nil)
    }

    @Test func heroIsCachedUntilMetadataIsInvalidated() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL == nil)
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", backdropPath: "/b.jpg", language: "sv-SE"),
            now: Date())
        // Cachad hero: databasen läses inte om.
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL == nil)
        m.invalidateMetadataCaches(playlistID: id)
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL != nil)
    }

    @Test func heroCacheEvictsLeastRecentlyUsed() {
        let playlist = UUID()
        func key(_ id: String) -> HeroKey {
            HeroKey(playlistID: playlist, kind: .movie, providerID: id, kidsRestricted: false)
        }
        func hero(_ id: String) -> HeroInfo {
            AppModel.makeHero(item: LibraryItem(kind: .movie, providerID: id, title: id, year: nil, posterURL: nil),
                              metadata: nil, container: nil, showExternalRatings: false)
        }
        var cache = HeroCache(capacity: 2)
        cache.insert(hero("a"), for: key("a"))
        cache.insert(hero("b"), for: key("b"))
        #expect(cache.value(for: key("a")) != nil)   // a blir senast använd
        cache.insert(hero("c"), for: key("c"))        // b ryker
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.value(for: key("a")) != nil && cache.value(for: key("c")) != nil)
        #expect(cache.count == 2)
        #expect(HeroCache().capacity == 200)

        // Samma titel för barnläge och vuxenläge är olika poster.
        let kidsKey = HeroKey(playlistID: playlist, kind: .movie, providerID: "a", kidsRestricted: true)
        #expect(cache.value(for: kidsKey) == nil)

        cache.removeAll { $0.providerID == "a" }
        #expect(cache.value(for: key("a")) == nil && cache.count == 1)
    }

    @Test func unmatchedPosterLookupIsCachedNegatively() async throws {
        let (m, id) = try await heroModel()
        // 102 har ingen metadata alls.
        let item = try movieItem(m, id, "102")
        #expect(m.tmdbPosterReads == 0)
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 1)
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 1)   // inga fler databasläsningar

        // Matchad titel vars metadata saknar affisch räknas också som miss.
        let noPoster = try movieItem(m, id, "101")
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", language: "sv-SE"),
                                         now: Date())
        #expect(await m.tmdbPosterURL(for: noPoster, playlistID: id) == nil)
        #expect(await m.tmdbPosterURL(for: noPoster, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 2)

        // Metadata uppdateras: missen glöms och affischen hittas.
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", posterPath: "/p.jpg", language: "sv-SE"),
            now: Date())
        #expect(await m.tmdbPosterURL(for: noPoster, playlistID: id) == nil)   // fortfarande minns missen
        m.invalidateMetadataCaches(playlistID: id)
        let url = await m.tmdbPosterURL(for: noPoster, playlistID: id)
        #expect(url == TMDBImage.url(path: "/p.jpg", size: ArtworkKind.poster.tmdbSize))
        #expect(m.tmdbPosterReads == 3)   // 101 lästes om och hittade nu affischen
        #expect(await m.tmdbPosterURL(for: noPoster, playlistID: id) == url)
        #expect(m.tmdbPosterReads == 3)   // träffen minns vi också

        // Live gör ingen läsning alls.
        let live = LibraryItem(kind: .live, providerID: "1", title: "K", year: nil, posterURL: nil)
        #expect(await m.tmdbPosterURL(for: live, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 3)
    }

    @Test func posterMissIsInvalidatedOnlyForItsPlaylist() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "102")
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        m.invalidateMetadataCaches(playlistID: UUID())   // en annan spellista
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 1)
        m.invalidateMetadataCaches(playlistID: id)
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 2)
    }

    // MARK: - Fix round 1

    @Test func staleKidsDecisionIsNeitherServedNorCached() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        try await selectKids(m, id)
        let item = try movieItem(m, id, "101")
        // Under läsningen berikas titeln om: åldersgränsen blir 18 och cacherna ogiltigförklaras.
        m.heroAfterReadHook = {
            m.heroAfterReadHook = nil
            try? m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm",
                                                            ageLimit: 18, language: "sv-SE"), now: Date())
            m.discovery.invalidate(playlistID: id)
            m.invalidateMetadataCaches(playlistID: id)
        }
        #expect(await m.hero(for: item, playlistID: id) == nil)
        #expect(m.heroCache.count == 0)
        #expect(await m.hero(for: item, playlistID: id) == nil)
    }

    @Test func kidsAgeIsRecheckedAgainstReadMetadata() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        try await selectKids(m, id)
        let item = try movieItem(m, id, "101")
        #expect(await m.canOpenTitle(kind: .movie, providerID: "101", playlistID: id))   // bygger upptäcktens cache
        // Databasen ändras utan att upptäckten ogiltigförklaras: åldersprövningen via `canOpenTitle` är föråldrad.
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm", ageLimit: 18,
                                                       language: "sv-SE"), now: Date())
        #expect(await m.canOpenTitle(kind: .movie, providerID: "101", playlistID: id))
        #expect(await m.hero(for: item, playlistID: id) == nil)
        #expect(m.heroCache.count == 0)
    }

    @Test func kidsHeroIsServedFromCache() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        try await selectKids(m, id)
        let item = try movieItem(m, id, "101")
        let first = try #require(await m.hero(for: item, playlistID: id))
        #expect(m.heroCache.count == 1)
        // Ändring utan ogiltigförklaring: svaret kommer ur cachen (ingen ny läsning).
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 12345, kind: .movie, title: "Barnfilm",
                                                       backdropPath: "/b.jpg", ageLimit: 7, language: "sv-SE"),
                                         now: Date())
        #expect(await m.hero(for: item, playlistID: id) == first)
        #expect(first.backdropURL == nil)
        m.invalidateMetadataCaches(playlistID: id)
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL != nil)
    }

    @Test func openingDetailThatSavedMetadataRefreshesPosterAndHero() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        let other = try movieItem(m, id, "102")
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        #expect(await m.tmdbPosterURL(for: other, playlistID: id) == nil)
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL == nil)
        #expect(m.tmdbPosterReads == 2)

        // Detaljsidan hämtar och sparar metadata (här: tjänsten läser den nysparade posten).
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", posterPath: "/p.jpg", backdropPath: "/b.jpg",
                          language: "sv-SE"), now: Date())
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)   // missen sitter kvar tills detaljsidan
        let detail = try #require(await m.titleDetail(kind: .movie, providerID: "101", playlistID: id))
        #expect(detail.hasMetadata)
        #expect(await m.tmdbPosterURL(for: item, playlistID: id)
                == TMDBImage.url(path: "/p.jpg", size: ArtworkKind.poster.tmdbSize))
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL != nil)
        // Andra titlars missar rörs inte.
        #expect(await m.tmdbPosterURL(for: other, playlistID: id) == nil)
        #expect(m.tmdbPosterReads == 3)
    }

    @Test func readErrorIsNotCached() async throws {
        let db = try AppDatabase.inMemory()
        let m = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        let id = try #require(m.playlists.first?.id)
        m.enter(playlistID: id)
        let item = try movieItem(m, id, "101")
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", posterPath: "/p.jpg", backdropPath: "/b.jpg",
                          language: "sv-SE"), now: Date())

        // Matchningstabellen försvinner en stund: läsningarna misslyckas.
        try await db.writer.write { try $0.execute(sql: "ALTER TABLE tmdbMatch RENAME TO tmdbMatchAway") }
        #expect(await m.tmdbPosterURL(for: item, playlistID: id) == nil)
        let fallback = try #require(await m.hero(for: item, playlistID: id))
        #expect(fallback.backdropURL == nil)
        #expect(m.heroCache.count == 0)
        #expect(m.tmdbPosterMisses.isEmpty)

        try await db.writer.write { try $0.execute(sql: "ALTER TABLE tmdbMatchAway RENAME TO tmdbMatch") }
        #expect(await m.tmdbPosterURL(for: item, playlistID: id)
                == TMDBImage.url(path: "/p.jpg", size: ArtworkKind.poster.tmdbSize))
        #expect(await m.hero(for: item, playlistID: id)?.backdropURL != nil)
        #expect(m.tmdbPosterReads == 2)
    }

    @Test func posterMissMemoryIsCapped() async throws {
        let (m, id) = try await heroModel()
        m.tmdbPosterMissLimit = 2
        for providerID in ["101", "102", "103"] {
            #expect(await m.tmdbPosterURL(for: try movieItem(m, id, providerID), playlistID: id) == nil)
        }
        #expect(m.tmdbPosterMisses.count == 1)   // töms när gränsen nåddes, sedan nästa miss
    }

    // MARK: - HeroModel (Hem på tvOS)

    @Test func lateHeroResponseForReplacedFocusIsIgnored() async throws {
        let gate = GatedHeroLoader(slow: ["A"])
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: RecordingArtworkBackend()), loader: gate.load)
        let playlist = UUID()
        let a = hero.focus(heroItem("A"), playlistID: playlist)
        while gate.waiting["A"] == nil { await Task.yield() }
        let b = hero.focus(heroItem("B"), playlistID: playlist)
        await b.value
        #expect(hero.current?.providerID == "B")
        gate.release("A")
        await a.value
        #expect(hero.current?.providerID == "B")   // A:s sena svar skriver inte över B
    }

    @Test func previousHeroStaysUntilNewOneArrives() async throws {
        let gate = GatedHeroLoader(slow: ["B"])
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: RecordingArtworkBackend()), loader: gate.load)
        let playlist = UUID()
        await hero.focus(heroItem("A"), playlistID: playlist).value
        let b = hero.focus(heroItem("B"), playlistID: playlist)
        while gate.waiting["B"] == nil { await Task.yield() }
        #expect(hero.current?.providerID == "A")   // ingen tom ruta under laddningen
        gate.release("B")
        await b.value
        #expect(hero.current?.providerID == "B")
        // Fokus utanför raderna (nil) behåller heron.
        hero.focus(nil, playlistID: playlist)
        #expect(hero.current?.providerID == "B")
    }

    @Test func focusedTitleWithoutMetadataGetsEnrichedHero() async throws {
        let plain = GatedHeroLoader(slow: [])
        let logo = URL(string: "https://image.tmdb.org/t/p/w500/logo.png")!
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: RecordingArtworkBackend()), loader: plain.load,
                             enricher: { item, _ in
            HeroInfo(kind: item.kind, providerID: item.providerID, title: item.title, year: nil, runtimeMinutes: nil,
                     certification: nil, ratings: [], overview: "Beskrivning", backdropURL: nil, logoURL: logo,
                     badges: [], posterURL: item.posterURL)
        })
        await hero.focus(heroItem("A"), playlistID: UUID()).value
        #expect(hero.current?.logoURL == logo)
        #expect(hero.current?.overview == "Beskrivning")
    }

    @Test func lateEnrichmentForReplacedFocusIsIgnored() async throws {
        let plain = GatedHeroLoader(slow: [])
        let gate = GatedHeroLoader(slow: ["A"])
        let logo = URL(string: "https://image.tmdb.org/t/p/w500/logo.png")!
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: RecordingArtworkBackend()), loader: plain.load,
                             enricher: { item, playlistID in
            guard item.providerID == "A" else { return nil }
            _ = await gate.load(item, playlistID)   // väntar tills testet släpper A
            return HeroInfo(kind: item.kind, providerID: "A", title: item.title, year: nil, runtimeMinutes: nil,
                            certification: nil, ratings: [], overview: nil, backdropURL: nil, logoURL: logo,
                            badges: [], posterURL: nil)
        })
        let a = hero.focus(heroItem("A"), playlistID: UUID())
        while gate.waiting["A"] == nil { await Task.yield() }
        await hero.focus(heroItem("B"), playlistID: UUID()).value
        gate.release("A")
        await a.value
        #expect(hero.current?.providerID == "B")   // A:s sena hämtning skriver inte över B
        #expect(hero.current?.logoURL == nil)
    }

    @Test func prefetchWindowCoversVisibleRowsPlusOneScreen() {
        let rows = (0..<6).map { homeRow($0, count: 15) }
        let plan = HeroModel.plan(rows: rows, focusedRow: 2, focusedIndex: 5)
        // Synliga rader 2 och 3, plus en rad åt vardera håll: 1...4. Fokuserad rad: tio efter fokus.
        var expected = Set<URL>()
        for row in 1...4 {
            let count = row == 2 ? 5 + HeroModel.postersPerRow : HeroModel.postersPerRow
            for i in 0..<count { expected.insert(poster(row, i)) }
        }
        #expect(plan.posters == expected)
        #expect(!plan.posters.contains(poster(0, 0)) && !plan.posters.contains(poster(5, 0)))
        // Backdrop för fokuserad ±3 titlar.
        #expect(plan.backdropItems.map(\.providerID) == (2...8).map { "r2-\($0)" })
        // Kanter: början av raden och en rad som inte finns.
        #expect(HeroModel.plan(rows: rows, focusedRow: 0, focusedIndex: 0).backdropItems.count == 4)
        #expect(HeroModel.plan(rows: rows, focusedRow: 9, focusedIndex: 0).backdropItems.isEmpty)
        #expect(HeroModel.plan(rows: [], focusedRow: 0, focusedIndex: 0).posters.isEmpty)
    }

    @Test func prefetchWindowDiffsAndPairsWithCancel() async throws {
        let backend = RecordingArtworkBackend()
        let loader = GatedHeroLoader(slow: [], backdropFor: backdropURL)
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: backend), loader: loader.load)
        let rows = (0..<8).map { homeRow($0, count: 12) }
        let playlist = UUID()

        hero.prefetchWindow(rows: rows, focusedRow: 2, focusedIndex: 0, playlistID: playlist)
        await hero.backdropTask?.value
        let firstStarted = Set(backend.started.map(\.url))
        #expect(backend.started.count == firstStarted.count)   // inget hämtas två gånger
        #expect(backend.started.filter { $0.kind == .backdrop }.count == 4)   // fokus 0 ±3, klippt
        #expect(backend.cancelled.isEmpty)

        // Samma fönster igen: ingenting nytt.
        hero.prefetchWindow(rows: rows, focusedRow: 2, focusedIndex: 0, playlistID: playlist)
        await hero.backdropTask?.value
        #expect(backend.started.count == firstStarted.count && backend.cancelled.isEmpty)

        // Ett steg ner: bara den nya raden förhämtas, bara den bortfallna raden avbryts.
        let before = backend.started.count
        hero.prefetchWindow(rows: rows, focusedRow: 3, focusedIndex: 0, playlistID: playlist)
        await hero.backdropTask?.value
        let newPosters = backend.started.dropFirst(before).filter { $0.kind == .poster }.map(\.url)
        #expect(Set(newPosters) == Set((0..<HeroModel.postersPerRow).map { poster(5, $0) }))
        let droppedPosters = backend.cancelled.filter { $0.kind == .poster }.map(\.url)
        #expect(Set(droppedPosters) == Set((0..<HeroModel.postersPerRow).map { poster(1, $0) }))

        // reset avbryter allt som återstår: varje start har exakt ett avbryt.
        hero.reset()
        #expect(Set(backend.started) == Set(backend.cancelled))
        #expect(backend.started.count == backend.cancelled.count)
    }

    @Test func prefetchUsesTheTMDBPosterWhenKnown() async throws {
        let backend = RecordingArtworkBackend()
        let loader = GatedHeroLoader(slow: [], backdropFor: backdropURL)
        let tmdb = URL(string: "https://example.invalid/tmdb-r0-1.jpg")!
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: backend), loader: loader.load,
                             posterResolver: { item, _ in item.providerID == "r0-1" ? tmdb : nil })
        hero.prefetchWindow(rows: [homeRow(0, count: 3)], focusedRow: 0, focusedIndex: 0, playlistID: UUID())
        await hero.backdropTask?.value
        let posters = Set(backend.started.filter { $0.kind == .poster }.map(\.url))
        // Samma adress som kortet visar: TMDB för den cachade titeln, leverantörens för resten.
        #expect(posters == [poster(0, 0), tmdb, poster(0, 2)])
    }

    @Test func cachedTMDBPosterIsReadWithoutDatabase() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        #expect(m.cachedTMDBPosterURL(for: item, playlistID: id) == nil)
        try m.metadataStore.saveMetadata(
            TitleMetadata(tmdbID: 12345, kind: .movie, title: "T", posterPath: "/p.jpg", language: "sv-SE"),
            now: Date())
        #expect(m.cachedTMDBPosterURL(for: item, playlistID: id) == nil)   // inte löst än: ingen läsning
        let reads = m.tmdbPosterReads
        let url = await m.tmdbPosterURL(for: item, playlistID: id)
        #expect(url != nil)
        #expect(m.cachedTMDBPosterURL(for: item, playlistID: id) == url)
        #expect(m.tmdbPosterReads == reads + 1)
        m.invalidateMetadataCaches(playlistID: id)
        #expect(m.cachedTMDBPosterURL(for: item, playlistID: id) == nil)
    }

    @Test func backdropResolvedAfterResetIsNotPrefetched() async throws {
        let backend = RecordingArtworkBackend()
        let loader = GatedHeroLoader(slow: ["r0-0"], backdropFor: backdropURL)
        let hero = HeroModel(pipeline: ArtworkPipeline(backend: backend), loader: loader.load)
        hero.prefetchWindow(rows: [homeRow(0, count: 3)], focusedRow: 0, focusedIndex: 0, playlistID: UUID())
        let task = hero.backdropTask
        while loader.waiting["r0-0"] == nil { await Task.yield() }
        hero.reset()
        loader.release("r0-0")
        await task?.value
        #expect(backend.started.filter { $0.kind == .backdrop }.isEmpty)
        #expect(backend.started.count == backend.cancelled.count)
    }

    @Test func heroPanelActionsWriteToPersonalStore() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        let hero = HeroModel()
        hero.attach(m)
        await hero.focus(item, playlistID: id).value
        let ref = try #require(hero.current?.ref)
        #expect(ref.providerID == "101" && !m.isInMyList(ref))
        m.toggleMyList(ref)   // knappen Min lista i panelen
        #expect(m.isInMyList(ref))
        #expect(m.activeProfile?.personal.isInMyList(ref) == true)
        m.toggleRating(.up, for: ref)   // 👍
        #expect(m.rating(ref) == .up)
        #expect(m.activeProfile?.personal.rating(ref) == .up)
        m.toggleRating(.up, for: ref)
        #expect(m.rating(ref) == nil)
    }

    @Test func homeWithoutMetadataShowsProviderFallbackHero() async throws {
        let (m, id) = try await heroModel()
        let item = try movieItem(m, id, "101")
        let hero = HeroModel()
        hero.attach(m)
        await hero.focus(item, playlistID: id).value
        let current = try #require(hero.current)
        #expect(current.title == item.title)
        #expect(current.backdropURL == nil && current.logoURL == nil)
        // Bakgrunden faller tillbaka på affischen.
        #expect(HeroBackdrop.imageURL(for: current) == item.posterURL)
        let withBackdrop = AppModel.makeHero(
            item: item, metadata: TitleMetadata(tmdbID: 1, kind: .movie, title: "T", backdropPath: "/b.jpg",
                                                language: "sv-SE"), container: nil, showExternalRatings: false)
        #expect(HeroBackdrop.imageURL(for: withBackdrop) == withBackdrop.backdropURL)
    }

    @Test func kidsFocusNeverReachesHeroForDeniedTitle() async throws {
        let (m, id) = try await heroModel()
        try seedAges(m, id)
        try await selectKids(m, id)
        let hero = HeroModel()
        hero.attach(m)
        await hero.focus(try movieItem(m, id, "101"), playlistID: id).value
        #expect(hero.current?.providerID == "101")
        await hero.focus(try movieItem(m, id, "103"), playlistID: id).value   // 18 år
        #expect(hero.current == nil)
        await hero.focus(try movieItem(m, id, "101"), playlistID: id).value
        await hero.focus(try movieItem(m, id, "102"), playlistID: id).value   // oklassad
        #expect(hero.current == nil)
        hero.reset()
        #expect(hero.current == nil)
    }

    @Test func reduceMotionDisablesCrossfade() {
        #expect(HeroModel.crossfade(reduceMotion: true) == nil)
        #expect(HeroModel.crossfade(reduceMotion: false) != nil)
    }
}

// MARK: - Testverktyg för HeroModel

private func poster(_ row: Int, _ index: Int) -> URL {
    URL(string: "https://example.invalid/p-\(row)-\(index).jpg")!
}

private func backdropURL(_ item: LibraryItem) -> URL {
    URL(string: "https://example.invalid/bd-\(item.providerID).jpg")!
}

private func heroItem(_ id: String) -> LibraryItem {
    LibraryItem(kind: .movie, providerID: id, title: id, year: nil, posterURL: nil)
}

private func homeRow(_ row: Int, count: Int) -> HomeRow {
    HomeRow(id: .genre(row, .movie), title: "Rad \(row)", titles: (0..<count).map {
        LibraryItem(kind: .movie, providerID: "r\(row)-\($0)", title: "t", year: nil, posterURL: poster(row, $0))
    })
}

/// Hero-laddare som testet styr: valda titlar väntar tills `release`.
@MainActor
private final class GatedHeroLoader {
    private let slow: Set<String>
    private let backdropFor: ((LibraryItem) -> URL)?
    private(set) var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    init(slow: Set<String>, backdropFor: ((LibraryItem) -> URL)? = nil) {
        self.slow = slow
        self.backdropFor = backdropFor
    }

    func release(_ id: String) {
        waiting.removeValue(forKey: id)?.resume()
    }

    func load(_ item: LibraryItem, _ playlistID: UUID) async -> HeroInfo? {
        if slow.contains(item.providerID) {
            await withCheckedContinuation { waiting[item.providerID] = $0 }
        }
        return HeroInfo(kind: item.kind, providerID: item.providerID, title: item.title, year: nil,
                        runtimeMinutes: nil, certification: nil, ratings: [], overview: nil,
                        backdropURL: backdropFor?(item), logoURL: nil, badges: [], posterURL: item.posterURL)
    }
}

/// Registrerar förhämtningar utan nätverk; inget finns någonsin i cachen.
@MainActor
private final class RecordingArtworkBackend: ArtworkBackend {
    private(set) var started: [ArtworkRequest] = []
    private(set) var cancelled: [ArtworkRequest] = []
    func cachedImage(for request: ArtworkRequest) -> UIImage? { nil }
    func image(for request: ArtworkRequest) async throws -> UIImage { UIImage() }
    func startPrefetching(_ requests: [ArtworkRequest]) { started.append(contentsOf: requests) }
    func stopPrefetching(_ requests: [ArtworkRequest]) { cancelled.append(contentsOf: requests) }
}
