import Core
import Foundation
import GRDB
import Library
import Metadata
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

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
}
