import Core
import Foundation
import Library
import Personal
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

private func liveStream(_ id: String, _ name: String, category: String, epg: String? = nil) -> LiveStream {
    LiveStream(providerID: id, name: name, categoryID: category, epgChannelID: epg,
               locator: .xtream(kind: .live, streamID: id, container: "ts"))
}

private func liveCategory(_ id: String, _ name: String, _ index: Int) -> Core.Category {
    Core.Category(providerID: id, name: name, kind: .live, sortIndex: index)
}

/// Modell med en importerad Xtream-spellista (fixtures: två live-kanaler, "fake.news" och en utan tablå) och en vald
/// vuxenprofil.
@MainActor
private func liveModelFixture(http: HTTPClient = StubHTTPClient(fixtures: standardFixtures),
                              epgHTTP: HTTPClient? = nil) async throws -> (AppModel, UUID) {
    let store = LibraryStore(db: try .inMemory())
    let creds = InMemoryCredentialStore()
    // En egen HTTP-klient för tablåimporten gör att ett test kan låta den misslyckas utan att katalogimporten påverkas.
    let importer = epgHTTP.map { EPGImporter(store: store, epg: store.epg, credentials: creds, http: $0) }
    let m = AppModel(store: store, credentials: creds, http: http, defaults: freshDefaults(), epgImporter: importer)
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    let id = try #require(m.playlists.first?.id)
    m.enter(playlistID: id)
    try #require(!m.kidsRestricted)
    return (m, id)
}

@MainActor
struct LiveModelTests {
    // MARK: Sektioner

    @Test func sectionOrderIsFavoritesRecentsThenCategories() {
        let groups = ChannelGrouper.group([
            liveStream("1", "Alfa", category: "A"), liveStream("2", "Beta", category: "A"),
            liveStream("3", "Gamma", category: "B"),
        ])
        let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.displayName, $0.id) })
        let sections = LiveModel.buildSections(
            groups: groups, categories: [liveCategory("A", "Nyheter", 0), liveCategory("B", "Film", 1)],
            favoriteIDs: [byName["Gamma"]!, byName["Alfa"]!], recentIDs: [byName["Beta"]!])
        #expect(sections.map(\.id) == ["favorites", "recents", "category/A", "category/B"])
        // Favoriter nyast först; kopior av samma grupper som i kategorierna.
        #expect(sections[0].groups.map(\.displayName) == ["Gamma", "Alfa"])
        #expect(sections[1].groups.map(\.displayName) == ["Beta"])
        #expect(sections[2].groups.map(\.displayName) == ["Alfa", "Beta"])
        #expect(sections[3].groups.map(\.displayName) == ["Gamma"])
        #expect(sections.map(\.kind) == [.favorites, .recents, .category("A"), .category("B")])
    }

    @Test func categoriesFollowProviderOrderNotAlphabetical() {
        let groups = ChannelGrouper.group([liveStream("1", "Alfa", category: "A"), liveStream("2", "Beta", category: "B")])
        let sections = LiveModel.buildSections(
            groups: groups, categories: [liveCategory("B", "Zzz", 0), liveCategory("A", "Aaa", 1)],
            favoriteIDs: [], recentIDs: [])
        #expect(sections.map(\.id) == ["category/B", "category/A"])
    }

    @Test func emptySectionsOmitted() {
        let groups = ChannelGrouper.group([liveStream("1", "Alfa", category: "A")])
        // Tom kategori, okända favorit- och senast sedda-id:n (t.ex. efter en uppdelning) ger inga sektioner.
        let sections = LiveModel.buildSections(
            groups: groups, categories: [liveCategory("A", "Nyheter", 0), liveCategory("Z", "Tom", 1)],
            favoriteIDs: ["finns-inte"], recentIDs: ["finns-inte-heller"])
        #expect(sections.map(\.id) == ["category/A"])
        #expect(LiveModel.buildSections(groups: [], categories: [liveCategory("A", "Nyheter", 0)],
                                        favoriteIDs: [], recentIDs: []).isEmpty)
    }

    @Test func groupsWithoutKnownCategoryEndUpLast() {
        let groups = ChannelGrouper.group([liveStream("1", "Alfa", category: "A"), liveStream("2", "Beta", category: "X")])
        let sections = LiveModel.buildSections(groups: groups, categories: [liveCategory("A", "Nyheter", 0)],
                                               favoriteIDs: [], recentIDs: [])
        #expect(sections.map(\.id) == ["category/A", "category/"])
        #expect(sections.last?.groups.map(\.displayName) == ["Beta"])
    }

    // MARK: Barnläge

    @Test func kidsProfileGetsNoGroupsAndNoEpg() async throws {
        let (m, id) = try await liveModelFixture()
        let adult = try #require(m.activeProfile?.profile)
        let groups = try await m.liveGroups(playlistID: id)
        #expect(!groups.isEmpty)
        let now = Date()
        try m.epg.replacePrograms(playlistID: id, programs: [
            EPGProgram(channelID: "fake.news", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600),
                       title: "Nyheter"),
        ], fetchedAt: now)
        let adultSeesEpg = await m.nowNext(playlistID: id, xmltvIDs: ["fake.news"], at: now)
        #expect(adultSeesEpg.count == 1)
        let adultGroup = try #require(groups.first)
        #expect(m.toggleFavoriteChannel(adultGroup.id))

        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: kid, pin: nil)
        try #require(m.kidsRestricted)

        #expect(try await m.liveGroups(playlistID: id).isEmpty)
        #expect(await m.liveCategories(playlistID: id).isEmpty)
        #expect(await m.epgMap(playlistID: id, groups: groups).isEmpty)
        #expect(await m.nowNext(playlistID: id, xmltvIDs: ["fake.news"], at: now).isEmpty)
        #expect(await m.shortNowNext(playlistID: id, groups: groups, at: now).isEmpty)
        #expect(m.favoriteChannelIDs().isEmpty)
        #expect(m.recentChannelIDs().isEmpty)
        #expect(!m.toggleFavoriteChannel(adultGroup.id))
        m.noteChannelWatched(adultGroup.id)
        #expect(m.recentChannelIDs().isEmpty)
        await m.splitChannel(playlistID: id, providerID: "9001", split: true)
        #expect(try m.epg.splitProviderIDs(playlistID: id).isEmpty)
        #expect(await m.refreshEPGIfNeeded(playlistID: id) == nil)
        #expect(m.liveRequest(group: adultGroup, playlistID: id, displaySupportsHDR: false) == nil)

        let live = LiveModel(model: m, playlistID: id)
        await live.load()
        #expect(live.sections.isEmpty)
        #expect(live.nowNext.isEmpty)
        #expect(!live.failed)

        // Utan vald profil är läget också stängt.
        m.switchProfile()
        #expect(try await m.liveGroups(playlistID: id).isEmpty)
        #expect(await m.refreshEPGIfNeeded(playlistID: id) == nil)
        // Vuxenprofilens favorit är orörd.
        try await m.select(profile: adult, pin: nil)
        #expect(m.favoriteChannelIDs() == [adultGroup.id])
    }

    // MARK: Tablå

    @Test func nowNextOnlyForRequestedChannels() async throws {
        let (m, id) = try await liveModelFixture()
        let now = Date()
        func program(_ channel: String, _ title: String) -> EPGProgram {
            EPGProgram(channelID: channel, start: now.addingTimeInterval(-300), end: now.addingTimeInterval(900),
                       title: title)
        }
        try m.epg.replacePrograms(playlistID: id, programs: [program("fake.news", "A"), program("annan", "B")],
                                  fetchedAt: now)
        let result = await m.nowNext(playlistID: id, xmltvIDs: ["fake.news"], at: now)
        #expect(Set(result.keys) == ["fake.news"])
        #expect(result["fake.news"]?.now?.title == "A")
        #expect(await m.nowNext(playlistID: id, xmltvIDs: [], at: now).isEmpty)
    }

    @Test func epgMapUsesStoredMatchAndFallsBackToOwnIDsBeforeFirstImport() async throws {
        let (m, id) = try await liveModelFixture()
        let groups = try await m.liveGroups(playlistID: id)
        let news = try #require(groups.first { $0.displayName == "Fake News" })
        // Före första importen: gruppens egen epgChannelID (bara grupper som har ett).
        #expect(await m.epgMap(playlistID: id, groups: groups) == [news.id: "fake.news"])
        // Efter en import gäller den sparade kopplingen (t.ex. namnmatchning) och inget annat.
        try m.epg.setChannelMap(playlistID: id, map: [news.id: "svt1.se"])
        #expect(await m.epgMap(playlistID: id, groups: groups) == [news.id: "svt1.se"])
        // En grupp som saknas i kopplingen (t.ex. nyss uppdelad) får sin egen epgChannelID.
        try m.epg.setChannelMap(playlistID: id, map: ["annan-grupp": "svt1.se"])
        #expect(await m.epgMap(playlistID: id, groups: groups) == ["annan-grupp": "svt1.se", news.id: "fake.news"])
    }

    @Test func liveModelLoadsSectionsAndNowNext() async throws {
        let (m, id) = try await liveModelFixture()
        let groups = try await m.liveGroups(playlistID: id)
        let news = try #require(groups.first { $0.displayName == "Fake News" })
        let now = Date()
        try m.epg.replacePrograms(playlistID: id, programs: [
            EPGProgram(channelID: "fake.news", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(900),
                       title: "Nyheter"),
            EPGProgram(channelID: "fake.news", start: now.addingTimeInterval(900), end: now.addingTimeInterval(1800),
                       title: "Väder"),
        ], fetchedAt: now)
        #expect(m.toggleFavoriteChannel(news.id))

        let live = LiveModel(model: m, playlistID: id)
        await live.load()
        #expect(live.sections.first?.id == "favorites")
        #expect(live.favoriteIDs == [news.id])
        // Inga synliga rader än: inget "Nu/Nästa" läses.
        #expect(live.nowNext.isEmpty)
        live.setVisible([news.id])
        await live.refreshNowNext(for: live.visibleGroups)
        #expect(live.nowNext[news.id]?.now?.title == "Nyheter")
        #expect(live.nowNext[news.id]?.next?.title == "Väder")
        // Bara de synliga kanalerna får "Nu/Nästa".
        #expect(Set(live.nowNext.keys) == [news.id])
    }

    @Test func shortEPGFallbackPicksCurrentAndNext() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let programs = [
            EPGProgram(channelID: "1", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), title: "C"),
            EPGProgram(channelID: "1", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1800), title: "B"),
            EPGProgram(channelID: "1", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-600), title: "A"),
        ]
        let result = AppModel.nowNext(from: programs, at: now)
        #expect(result?.now?.title == "B")
        #expect(result?.next?.title == "C")
        #expect(AppModel.nowNext(from: [], at: now) == nil)
        #expect(AppModel.nowNext(from: [programs[2]], at: now) == nil)
    }

    @Test func shortEPGFallbackFetchesOnceAndCaches() async throws {
        let now = Date()
        func ts(_ offset: TimeInterval) -> String { String(Int(now.timeIntervalSince1970 + offset)) }
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        let json = """
        {"epg_listings":[
          {"id":"1","title":"\(b64("Nyheter"))","description":"","start_timestamp":"\(ts(-300))","stop_timestamp":"\(ts(900))"},
          {"id":"2","title":"\(b64("Väder"))","description":"","start_timestamp":"\(ts(900))","stop_timestamp":"\(ts(1800))"}
        ]}
        """
        var responses: [String: StubResponse] = [:]
        for (action, file) in standardFixtures { responses[action] = try .fixture(file) }
        responses["get_short_epg"] = StubResponse(body: Data(json.utf8))
        let http = StubHTTPClient(responses: responses)
        let (m, id) = try await liveModelFixture(http: http)
        let groups = try await m.liveGroups(playlistID: id)
        let news = try #require(groups.first { $0.displayName == "Fake News" })

        let first = await m.shortNowNext(playlistID: id, groups: [news], at: now)
        #expect(first[news.id]?.now?.title == "Nyheter")
        #expect(first[news.id]?.next?.title == "Väder")
        #expect(http.requestCount(action: "get_short_epg") == 1)
        // Andra anropet inom 5 minuter tas ur minnescachen.
        let second = await m.shortNowNext(playlistID: id, groups: [news], at: now.addingTimeInterval(60))
        #expect(second[news.id]?.now?.title == "Nyheter")
        #expect(http.requestCount(action: "get_short_epg") == 1)
    }

    @Test func shortEPGCacheExpiresAfterFiveMinutes() {
        let cache = ShortEPGCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(cache.cached("k", at: t0) == nil)
        cache.store(nil, for: "k", at: t0)
        // Ett tomt svar är också ett svar: `.some(nil)`.
        let hit = cache.cached("k", at: t0.addingTimeInterval(299))
        #expect(hit != nil)
        #expect(hit! == nil)
        #expect(cache.cached("k", at: t0.addingTimeInterval(301)) == nil)
    }

    // MARK: Uppdatering

    @Test func retryBackoffAfterFailureIsThirtyMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(AppModel.epgRetryAllowed(lastFailure: nil, now: t0))
        #expect(!AppModel.epgRetryAllowed(lastFailure: t0, now: t0.addingTimeInterval(29 * 60)))
        #expect(AppModel.epgRetryAllowed(lastFailure: t0, now: t0.addingTimeInterval(30 * 60)))
    }

    @Test func failedRefreshBacksOffAndDoesNotRunConcurrently() async throws {
        // Tablåhämtningen får ett uttryckligt nätverksfel.
        let (m, id) = try await liveModelFixture(epgHTTP: FailingHTTPClient(URLError(.notConnectedToInternet)))
        let task = try #require(await m.refreshEPGIfNeeded(playlistID: id))
        // Pågår redan: ingen andra hämtning.
        #expect(await m.refreshEPGIfNeeded(playlistID: id) == nil)
        await task.value
        #expect(m.epgRefreshFailures[id] != nil)
        #expect(m.epgRefreshTasks[id] == nil)
        #expect(await m.refreshEPGIfNeeded(playlistID: id) == nil)
    }

    // MARK: Textlogga

    @Test func textLogoColorIsStablePerName() {
        // FNV-1a är fast mellan körningar (till skillnad från `hashValue`).
        #expect(ChannelLogoView.hue(for: "SVT1") == 83)
        #expect(ChannelLogoView.hue(for: "Kanal 5") == 23)
        #expect(ChannelLogoView.hue(for: "SVT1") == ChannelLogoView.hue(for: "SVT1"))
        for name in ["", "SVT1", "TV4 Film", "Åre TV"] {
            #expect((0..<360).contains(ChannelLogoView.hue(for: name)))
        }
        #expect(ChannelLogoView.initials(for: "SVT1") == "SV")
        #expect(ChannelLogoView.initials(for: "Kanal 5") == "K5")
        #expect(ChannelLogoView.initials(for: "TV4 Film Extra") == "TF")
        #expect(ChannelLogoView.initials(for: "") == "?")
    }
}
