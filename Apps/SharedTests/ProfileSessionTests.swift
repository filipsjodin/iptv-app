import Core
import Foundation
import Library
import Personal
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

@MainActor
private func profileModel(defaults: UserDefaults = freshDefaults(),
                          pins: any ProfilePinStore = InMemoryProfilePinStore()) async throws -> (AppModel, UUID) {
    let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults, pins: pins)
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    try #require(m.playlists.count == 1)
    return (m, m.playlists[0].id)
}

private func progress(_ playlistID: UUID, _ providerID: String) -> WatchProgress {
    WatchProgress(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: providerID),
                  position: 600, duration: 6000, watched: false, updatedAt: Date())
}

@MainActor
struct ProfileSessionTests {
    @Test func switchingProfileSwapsAllPersonalState() async throws {
        let (m, id) = try await profileModel()
        let a = try #require(m.profiles(for: id).first)
        let b = try m.addProfile(playlistID: id, name: "B", avatar: "star.fill")

        try await m.select(profile: a, pin: nil)
        m.userState.save(progress(id, "101"))
        let ref = ItemRef(kind: .movie, providerID: "101")
        #expect(m.activeProfile?.personal.toggleMyList(ref) == true)
        m.settings.engine = .vlc

        try await m.select(profile: b, pin: nil)
        #expect(m.activeProfile?.profile.id == b.id)
        #expect(await m.continueWatching(playlistID: id).isEmpty)
        #expect(m.activeProfile?.personal.myList().isEmpty == true)
        #expect(m.settings.engine == .automatic)

        try await m.select(profile: a, pin: nil)
        #expect(await m.continueWatching(playlistID: id).map(\.request.key.providerID) == ["101"])
        #expect(m.activeProfile?.personal.myList() == [ref])
        #expect(m.settings.engine == .vlc)
    }

    @Test func settingsPersistPerProfile() async throws {
        let defaults = freshDefaults()
        let (m, id) = try await profileModel(defaults: defaults)
        let a = try #require(m.profiles(for: id).first)
        try await m.select(profile: a, pin: nil)
        m.settings.engine = .vlc
        m.settings.tracks.audioLanguages = ["en", "sv", "de"]

        let again = AppModel(store: m.store, credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
        #expect(again.settings == PlaybackSettings())   // ingen aktiv profil ännu
        try await again.select(profile: a, pin: nil)
        #expect(again.settings.engine == .vlc)
        #expect(again.settings.tracks.audioLanguages == ["en", "sv", "de"])
    }

    @Test func singleProfileWithoutPinAutoSelected() async throws {
        let (m, id) = try await profileModel()
        #expect(m.activeProfile == nil)
        let only = try #require(m.profiles(for: id).first)
        #expect(m.profiles(for: id).count == 1)
        #expect(!only.hasPin)

        m.enter(playlistID: id)
        #expect(m.activeProfile?.profile.id == only.id)

        // Flera profiler: "Vem tittar?" (ingen automatisk väljning).
        m.switchProfile()
        try m.addProfile(playlistID: id, name: "B", avatar: "star.fill")
        m.enter(playlistID: id)
        #expect(m.activeProfile == nil)
    }

    @Test func singleProfileWithPinNotAutoSelected() async throws {
        let (m, id) = try await profileModel()
        let only = try #require(m.profiles(for: id).first)
        try m.updateProfile(only, pin: .set("1234"))
        m.enter(playlistID: id)
        #expect(m.activeProfile == nil)
    }

    @Test func wrongPinRejected() async throws {
        let pins = InMemoryProfilePinStore()
        let (m, id) = try await profileModel(pins: pins)
        let locked = try m.addProfile(playlistID: id, name: "Låst", avatar: "heart.fill", pin: "1234")
        #expect(locked.hasPin)

        await #expect(throws: ProfileError.wrongPin) { try await m.select(profile: locked, pin: "0000") }
        await #expect(throws: ProfileError.wrongPin) { try await m.select(profile: locked, pin: nil) }
        #expect(m.activeProfile == nil)
        try await m.select(profile: locked, pin: "1234")
        #expect(m.activeProfile?.profile.id == locked.id)

        // Utan PIN ignoreras koden helt; även en "fel" kod väljer profilen.
        let open = try #require(m.profiles(for: id).first { !$0.hasPin })
        try await m.select(profile: open, pin: "9999")
        #expect(m.activeProfile?.profile.id == open.id)

        // Ogiltig PIN vid skapande, och PIN kan tas bort i redigeraren.
        #expect(throws: ProfileError.invalidPin) {
            try m.addProfile(playlistID: id, name: "X", avatar: "star.fill", pin: "12a4")
        }
        try m.updateProfile(locked, pin: .remove)
        let unlocked = try #require(m.profiles(for: id).first { $0.id == locked.id })
        #expect(!unlocked.hasPin)
        #expect(try !pins.verify("1234", profileID: locked.id))
        try await m.select(profile: unlocked, pin: nil)
        #expect(m.activeProfile?.profile.id == locked.id)
    }

    @Test func deleteProfileClearsKeysAndPin() async throws {
        let defaults = freshDefaults()
        let pins = InMemoryProfilePinStore()
        let (m, id) = try await profileModel(defaults: defaults, pins: pins)
        let b = try m.addProfile(playlistID: id, name: "B", avatar: "star.fill", pin: "4321")
        try await m.select(profile: b, pin: "4321")
        m.userState.save(progress(id, "101"))
        _ = m.activeProfile?.personal.toggleMyList(ItemRef(kind: .movie, providerID: "101"))
        m.settings.engine = .vlc
        let keys = [ProfileKeys.progress(b.id), ProfileKeys.settings(b.id), ProfileKeys.personal(b.id)]
        for key in keys { #expect(defaults.data(forKey: key) != nil) }

        m.deleteProfile(b)
        for key in keys { #expect(defaults.data(forKey: key) == nil) }
        #expect(try !pins.verify("4321", profileID: b.id))
        #expect(m.activeProfile == nil)
        #expect(!m.profiles(for: id).contains { $0.id == b.id })
        #expect(m.profiles(for: id).count == 1)

        // Den sista profilen ersätts av en ny standardprofil utan PIN.
        let last = try #require(m.profiles(for: id).first)
        m.deleteProfile(last)
        let replacement = try #require(m.profiles(for: id).first)
        #expect(m.profiles(for: id).count == 1)
        #expect(replacement.id != last.id)
        #expect(!replacement.hasPin)
    }

    @Test func onePersistentStoreInstancePerProfile() async throws {
        let (m, id) = try await profileModel()
        let a = try #require(m.profiles(for: id).first)
        let b = try m.addProfile(playlistID: id, name: "B", avatar: "star.fill")
        try await m.select(profile: a, pin: nil)
        let sessionA = try #require(m.activeProfile)
        let storeA = sessionA.userState as AnyObject
        try await m.select(profile: b, pin: nil)
        #expect(m.activeProfile !== sessionA)
        #expect((m.activeProfile?.userState as AnyObject) !== storeA)
        try await m.select(profile: a, pin: nil)
        #expect(m.activeProfile === sessionA)
        #expect((m.activeProfile?.userState as AnyObject) === storeA)
        #expect((m.userState as AnyObject) === storeA)
    }

    @Test func playbackAcquiresAndReleasesLease() async throws {
        let broker = StreamConnectionBroker()
        let playlistID = UUID()
        let request = PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: "m"),
                                      title: "m", locator: .xtream(kind: .movie, streamID: "m", container: "mp4"),
                                      container: "mp4", isLive: false)
        let model = PlayerScreenModel(session: makeSession(request), nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0) }, setIdleTimerDisabled: { _ in },
                                      broker: broker, playlistID: playlistID)
        await model.start()
        #expect(model.lease != nil)
        #expect(await broker.activeCount(playlistID: playlistID) == 1)
        #expect(model.session.engine != nil)

        model.stop()
        await model.releaseTask?.value
        #expect(model.lease == nil)
        #expect(await broker.activeCount(playlistID: playlistID) == 0)
    }

    @Test func secondPlaybackRevokesFirst() async throws {
        let broker = StreamConnectionBroker()
        let playlistID = UUID()
        await broker.setLimit(1, playlistID: playlistID)
        func request(_ id: String) -> PlaybackRequest {
            PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: id), title: id,
                            locator: .xtream(kind: .movie, streamID: id, container: "mp4"), container: "mp4",
                            isLive: false)
        }
        let first = PlayerScreenModel(session: makeSession(request("a")), nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0) }, setIdleTimerDisabled: { _ in },
                                      broker: broker, playlistID: playlistID)
        await first.start()
        let second = PlayerScreenModel(session: makeSession(request("b")), nextEpisodeProvider: nil,
                                       makeSession: { makeSession($0) }, setIdleTimerDisabled: { _ in },
                                       broker: broker, playlistID: playlistID)
        await second.start()

        #expect(first.revokedMessage != nil)
        #expect(first.session.engine == nil)
        #expect(second.lease != nil)
        #expect(second.session.engine != nil)
        #expect(await broker.activeCount(playlistID: playlistID) == 1)
        // Stängning efter återkallning släpper ingenting som inte längre är vårt.
        first.stop()
        #expect(await broker.activeCount(playlistID: playlistID) == 1)
        second.stop()
        await second.releaseTask?.value
        #expect(await broker.activeCount(playlistID: playlistID) == 0)
    }

    @Test func kidsProfileHidesLive() async throws {
        #expect(LibraryTab.visible(isKids: false) == [.movies, .series, .live])
        #expect(LibraryTab.visible(isKids: true) == [.movies, .series])

        let (m, id) = try await profileModel()
        let adult = try #require(m.profiles(for: id).first)
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: adult, pin: nil)
        #expect(m.libraryTabs.contains(.live))
        try await m.select(profile: kid, pin: nil)
        #expect(!m.libraryTabs.contains(.live))

        // Ändras en aktiv profil till barnprofil döljs Live direkt.
        try await m.select(profile: adult, pin: nil)
        var changed = adult
        changed.isKids = true
        try m.updateProfile(changed)
        #expect(!m.libraryTabs.contains(.live))
    }

    @Test func legacyDataMigratedOnFirstLaunch() async throws {
        let defaults = freshDefaults()
        let store = LibraryStore(db: try .inMemory())
        let inDB = Playlist(name: "DB", kind: .xtream)
        let onlyMeta = Playlist(name: "Meta", kind: .xtream)   // t.ex. efter att tvOS rensat databasen
        try store.upsertPlaylist(inDB)
        PlaylistMetadataStore(defaults: defaults).save(inDB)
        PlaylistMetadataStore(defaults: defaults).save(onlyMeta)
        do {
            // Äldre version: global nyckel för positioner och inställningar.
            let legacy = UserDefaultsUserStateStore(defaults: defaults, key: "userstate.progress.v1")
            legacy.save(progress(inDB.id, "101"))
            legacy.save(progress(onlyMeta.id, "202"))
            PlaybackSettings(engine: .vlc).save(to: defaults)
        }

        let m = AppModel(store: store, credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
        #expect(defaults.data(forKey: "userstate.progress.v1") == nil)
        #expect(defaults.data(forKey: PlaybackSettings.defaultsKey) == nil)

        let a = try #require(m.profiles(for: inDB.id).first)
        #expect(m.profiles(for: inDB.id).count == 1)
        try await m.select(profile: a, pin: nil)
        #expect(m.userState.progress(for: progress(inDB.id, "101").key)?.position == 600)
        #expect(m.settings.engine == .vlc)

        let b = try #require(m.profiles(for: onlyMeta.id).first)
        try await m.select(profile: b, pin: nil)
        #expect(m.userState.progress(for: progress(onlyMeta.id, "202").key)?.position == 600)
        #expect(m.userState.progress(for: progress(inDB.id, "101").key) == nil)

        // Andra start: inget skapas eller flyttas igen.
        let again = AppModel(store: store, credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
        #expect(again.profiles(for: inDB.id).map(\.id) == [a.id])
    }

    @Test func tmdbTokenPlaceholderMeansMissing() async throws {
        #expect(AppModel.usableToken(nil) == nil)
        #expect(AppModel.usableToken("") == nil)
        #expect(AppModel.usableToken("  ") == nil)
        #expect(AppModel.usableToken("$(TMDB_READ_ACCESS_TOKEN)") == nil)
        #expect(AppModel.usableToken(" abc ") == "abc")

        let (m, id) = try await profileModel()
        #expect(!m.metadataConfigured)
        m.scheduleMetadata([id])
        #expect(m.metadataTask == nil)   // ingen berikning utan nyckel
        await m.refreshMetadataStatus()
        #expect(m.matchedTitles == nil)
        // Upptäckt fungerar ändå.
        #expect(try !m.discovery.candidates(playlistID: id, kind: .movie).isEmpty)
    }
}
