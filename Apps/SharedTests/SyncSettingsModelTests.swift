import Core
import Foundation
import Library
import Personal
import PlaybackCore
import Providers
import ProvidersTestSupport
import Secrets
import Security
import Sync
import SyncMapping
import Testing
@testable import IPTVApp

// MARK: - Hjälpmedel

/// Tidtagare som aldrig löser ut: inget test sover eller väntar på riktiga timers.
@MainActor
private final class IdleScheduler: SyncScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncTimer {
        SyncTimer(cancel: {})
    }
}

/// Transport som alltid misslyckas med given orsak.
private struct FailingTransport: SyncTransport {
    let failure: SyncTransportFailure
    func fetchChanges() async throws -> [SyncRecord] { throw failure }
    func push(_ records: [SyncRecord]) async throws { throw failure }
    var remoteChanges: AsyncStream<Void> { AsyncStream { _ in } }
}

/// Lager som loggar flyttanropen. Inga riktiga Keychain-poster.
private final class RecordingStore: CredentialStore, KeychainSyncMigrating, @unchecked Sendable {
    // @unchecked Sendable: `recorded` skyddas av `lock`.
    private let lock = NSLock()
    private var recorded: [String] = []
    private let inner = InMemoryCredentialStore()

    var calls: [String] { lock.withLock { recorded } }

    func save(_ secret: PlaylistSecret, for id: UUID) throws { try inner.save(secret, for: id) }
    func load(for id: UUID) throws -> PlaylistSecret? { try inner.load(for: id) }
    func delete(for id: UUID) throws { try inner.delete(for: id) }
    func allPlaylistIDs() throws -> [UUID] { try inner.allPlaylistIDs() }
    func migrateToSynchronizable() throws { lock.withLock { recorded.append("migrate") } }
    func stopSynchronizing(deleteCloudCopy: Bool) throws {
        lock.withLock { recorded.append("stop(\(deleteCloudCopy))") }
    }
}

/// Keychain-växlingen som modellen anropar: loggar och väntar tills testet öppnar den.
@MainActor
private final class SetterProbe {
    private(set) var calls: [String] = []
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_ on: Bool, _ deleteCloudCopy: Bool) async {
        calls.append("\(on),\(deleteCloudCopy)")
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeModel(credentials: CredentialStore = InMemoryCredentialStore(),
                       defaults: UserDefaults = freshDefaults()) throws -> AppModel {
    AppModel(store: LibraryStore(db: try AppDatabase.inMemory()), credentials: credentials,
             http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
}

@MainActor
@discardableResult
private func addLocalPlaylist(_ model: AppModel) throws -> Playlist {
    let playlist = Playlist(id: UUID(), name: "Min", kind: .xtream)
    try model.store.upsertPlaylist(playlist)
    model.playlistMetadata.save(playlist)
    return playlist
}

/// En app med synk påslagen och en vuxenprofil aktiv (spellistans enda profil väljs av `enter`).
@MainActor
private func syncedModel(cloud: InMemoryCloud, credentials: CredentialStore = InMemoryCredentialStore())
    async throws -> (model: AppModel, coordinator: SyncCoordinator, playlist: Playlist) {
    let model = try makeModel(credentials: credentials)
    let playlist = try addLocalPlaylist(model)
    let coordinator = model.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
    await coordinator.setEnabled(true)
    model.enter(playlistID: playlist.id)
    return (model, coordinator, playlist)
}

private let allFailures: [SyncFailure] = [.noAccount, .offline, .quota, .other]

// MARK: - Tester

@MainActor
struct SyncSettingsModelTests {
    @Test func unavailableBuildDisablesToggleWithExplanation() async throws {
        let model = try makeModel()
        let playlist = try addLocalPlaylist(model)
        model.enter(playlistID: playlist.id)
        #expect(model.activeProfile != nil)

        for attached in [false, true] {
            // Med och utan en koordinator utan transport (standardbygget).
            if attached { model.attachSync(transport: nil, scheduler: IdleScheduler()) }
            let settings = SyncSettingsModel(app: model)
            #expect(settings.isVisible)
            #expect(!settings.isAvailable)
            #expect(!settings.syncToggleEnabled)
            #expect(!settings.canSyncNow)
            #expect(!settings.showsKeychainControls)
            #expect(!settings.keychainToggleEnabled)
            #expect(settings.statusText == nil)
            #expect(settings.unavailableExplanation == String(localized: "Requires a build with iCloud (developer account)"))
            await settings.setSyncEnabled(true)
            #expect(!settings.isSyncOn)
        }
        // Med transport finns ingen förklaring och omkopplaren är aktiv (men av).
        let cloud = InMemoryCloud()
        let live = try await syncedModel(cloud: cloud)
        let available = SyncSettingsModel(app: live.model)
        #expect(available.isAvailable)
        #expect(available.unavailableExplanation == nil)
        #expect(available.syncToggleEnabled)
    }

    @Test func statusTextForEveryFailure() async throws {
        var seen: Set<String> = []
        for failure in allFailures {
            let text = SyncSettingsModel.text(for: failure)
            #expect(!text.isEmpty)
            seen.insert(text)
        }
        #expect(seen.count == allFailures.count)  // varje orsak har egen text

        // Status från koordinatorn: misslyckad synk visar orsakens text.
        for (transportFailure, expected) in [(SyncTransportFailure.noAccount, SyncFailure.noAccount),
                                             (.offline, .offline), (.quota, .quota)] {
            let model = try makeModel()
            let playlist = try addLocalPlaylist(model)
            let coordinator = model.attachSync(transport: FailingTransport(failure: transportFailure),
                                               scheduler: IdleScheduler())
            model.enter(playlistID: playlist.id)
            await coordinator.setEnabled(true)
            let settings = SyncSettingsModel(app: model)
            #expect(coordinator.status == .failed(expected))
            #expect(settings.statusText == SyncSettingsModel.text(for: expected))
        }

        // Lyckad synk: "Senast synkad …"; av: ingen statusrad.
        let cloud = InMemoryCloud()
        let live = try await syncedModel(cloud: cloud)
        let settings = SyncSettingsModel(app: live.model)
        #expect(settings.statusText != nil)
        #expect(settings.statusText?.isEmpty == false)
        await settings.setSyncEnabled(false)
        #expect(settings.statusText == nil)
        #expect(!settings.isSyncOn)
    }

    @Test func profileDeletionCreatesTombstonesForChildren() async throws {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        let adult = try #require(a.model.activeProfile?.profile)
        let kid = try a.model.addProfile(playlistID: a.playlist.id, name: "Kid", avatar: "star.fill", isKids: true)
        try await a.model.select(profile: kid, pin: nil)
        let item = ItemRef(kind: .movie, providerID: "m1")
        _ = a.model.activeProfile?.personal.toggleMyList(item)
        a.model.noteSyncChange(SyncMapper.watchlistID(profile: kid.id, item: item))
        try await a.model.select(profile: adult, pin: nil)

        try a.model.deleteProfile(kid)
        await a.coordinator.flushNow()

        #expect(cloud.record(for: SyncMapper.profileID(kid.id))?.deleted == true)
        #expect(cloud.record(for: SyncMapper.watchlistID(profile: kid.id, item: item))?.deleted == true)
        #expect(cloud.record(for: SyncMapper.profileID(adult.id))?.deleted == false)
    }

    @Test func playlistRemovalTombstoneSyncs() async throws {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
        await cb.setEnabled(true)
        let adult = try #require(a.model.activeProfile?.profile)
        // En vuxenprofil med PIN: borttagning utan aktiv profil kräver den, som förut.
        try a.model.addProfile(playlistID: a.playlist.id, name: "Vuxen", avatar: "star.fill", pin: "1234")
        a.model.switchProfile()
        await #expect(throws: ProfileError.adultPinRequired) {
            try await a.model.remove(playlistID: a.playlist.id, adultPin: nil)
        }
        await a.coordinator.flushNow()
        #expect(cloud.record(for: SyncMapper.playlistID(a.playlist.id))?.deleted != true)
        #expect(try a.model.store.playlists().count == 1)

        try await a.model.remove(playlistID: a.playlist.id, adultPin: "1234")
        await a.coordinator.flushNow()
        #expect(cloud.record(for: SyncMapper.playlistID(a.playlist.id))?.deleted == true)
        #expect(cloud.record(for: SyncMapper.profileID(adult.id))?.deleted == true)

        await cb.syncNow()
        #expect(b.profiles(for: a.playlist.id).isEmpty)
        await b.remoteDeletionTask?.value
        await b.processRemotePlaylistDeletions()
        #expect(b.playlistMetadata.pendingRemoteDeletions().isEmpty)
    }

    @Test func turningOffKeychainSyncAsksAboutCloudCopy() async throws {
        let store = RecordingStore()
        let live = try await syncedModel(cloud: InMemoryCloud(), credentials: store)
        live.model.keychainSyncAvailable = true  // som ett synkbygge
        let settings = SyncSettingsModel(app: live.model)
        #expect(settings.showsKeychainControls)
        #expect(settings.keychainToggleEnabled)
        #expect(!settings.keychainOn)

        await settings.requestKeychain(true)
        #expect(settings.keychainOn)
        #expect(store.calls == ["migrate"])

        // Av: frågan ställs, ingenting ändras förrän svaret kommer.
        await settings.requestKeychain(false)
        #expect(settings.isAskingAboutCloudCopy)
        #expect(settings.keychainOn)
        #expect(store.calls == ["migrate"])
        #expect(!settings.keychainToggleEnabled)

        // Dialogen stängs utan svar: ingenting raderas, och svaret räknas fortfarande som en ställd fråga.
        settings.keychainQuestionDismissed()
        #expect(store.calls == ["migrate"])
        await settings.confirmKeychainOff(deleteCloudCopy: false)
        #expect(!settings.keychainOn)
        #expect(store.calls == ["migrate", "stop(false)"])
        // Utan ställd fråga gör ett svar ingenting.
        await settings.requestKeychain(true)
        await settings.confirmKeychainOff(deleteCloudCopy: true)
        #expect(settings.keychainOn)
        #expect(store.calls == ["migrate", "stop(false)", "migrate"])
        await settings.requestKeychain(false)

        // Avbryt: omkopplaren står kvar på.
        settings.cancelKeychainOff()
        #expect(!settings.isAskingAboutCloudCopy)
        #expect(settings.keychainOn)
        #expect(store.calls == ["migrate", "stop(false)", "migrate"])

        // Behåll i iCloud.
        await settings.requestKeychain(false)
        await settings.confirmKeychainOff(deleteCloudCopy: false)
        #expect(!settings.keychainOn)
        #expect(!live.model.keychainSyncActive)
        #expect(store.calls == ["migrate", "stop(false)", "migrate", "stop(false)"])

        // Ta bort från iCloud.
        await settings.requestKeychain(true)
        await settings.requestKeychain(false)
        await settings.confirmKeychainOff(deleteCloudCopy: true)
        #expect(!settings.keychainOn)
        #expect(store.calls.last == "stop(true)")
        #expect(settings.errorMessage == nil)
    }

    @Test func keychainToggleSerialized() async throws {
        let live = try await syncedModel(cloud: InMemoryCloud())
        live.model.keychainSyncAvailable = true
        let probe = SetterProbe()
        let settings = SyncSettingsModel(app: live.model, keychainSetter: { on, delete in await probe.run(on, delete) })

        let first = Task { await settings.requestKeychain(true) }
        var spins = 0
        while !settings.isRunning, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        #expect(settings.isRunning)
        #expect(!settings.keychainToggleEnabled)
        #expect(!settings.syncToggleEnabled)

        // Andra växlingen medan den första pågår ignoreras helt.
        await settings.requestKeychain(true)
        await settings.requestKeychain(false)
        #expect(!settings.isAskingAboutCloudCopy)
        #expect(probe.calls == ["true,false"])

        probe.open()
        await first.value
        #expect(!settings.isRunning)
        #expect(settings.keychainOn)
        #expect(probe.calls == ["true,false"])
    }

    @Test func kidsProfileCannotChangeSyncSettings() async throws {
        let store = RecordingStore()
        let live = try await syncedModel(cloud: InMemoryCloud(), credentials: store)
        live.model.keychainSyncAvailable = true
        let kid = try live.model.addProfile(playlistID: live.playlist.id, name: "Kid", avatar: "star.fill", isKids: true)
        try await live.model.select(profile: kid, pin: nil)
        #expect(live.model.kidsRestricted)

        let settings = SyncSettingsModel(app: live.model)
        #expect(!settings.isVisible)
        #expect(!settings.syncToggleEnabled)
        #expect(!settings.canSyncNow)
        #expect(!settings.showsKeychainControls)
        #expect(!settings.keychainToggleEnabled)

        await settings.setSyncEnabled(false)
        await settings.syncNow()
        await settings.requestKeychain(true)
        await settings.confirmKeychainOff(deleteCloudCopy: true)
        #expect(live.coordinator.isEnabled)  // orörd
        #expect(store.calls.isEmpty)
        #expect(!settings.keychainOn)

        // Utan aktiv profil räknas det som barnläge.
        live.model.switchProfile()
        #expect(!SyncSettingsModel(app: live.model).isVisible)
    }

    @Test func lockedProfileShowsExplanationInsteadOfSilentFailure() async throws {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        let adult = try a.model.addProfile(playlistID: a.playlist.id, name: "Vuxen", avatar: "star.fill", pin: "1234")
        await a.coordinator.flushNow()
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
        await cb.setEnabled(true)
        let onB = try #require(b.profiles(for: a.playlist.id).first { $0.id == adult.id })
        #expect(b.profileNeedsPin(adult.id))

        // Valet kastar, och felet ger förklaringen (vyn visar den i stället för att inget händer).
        var caught: Error?
        do { try await b.select(profile: onB, pin: nil) } catch { caught = error }
        let error = try #require(caught)
        #expect(SyncMissingCredentials.lockedProfileMessage(for: error) == SyncMissingCredentials.lockedProfile)
        #expect(UserFacingError.message(for: error) == SyncMissingCredentials.lockedProfile)
        #expect(!SyncMissingCredentials.lockedProfile.isEmpty)
        #expect(!SyncMissingCredentials.lockedProfileShort.isEmpty)
        // Redigering och borttagning är spärrade av samma skäl (editorn döljer kontrollerna).
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try b.deleteProfile(onB) }
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try b.updateProfile(onB) }
        // Övriga fel behåller sin hantering: ingen förklaring.
        #expect(SyncMissingCredentials.lockedProfileMessage(for: ProfileError.wrongPin) == nil)
        #expect(SyncMissingCredentials.lockedProfileMessage(for: ProfileError.notFound) == nil)
        // Standardbygget: ingen profil är någonsin låst.
        let plain = try makeModel()
        #expect(!plain.profileNeedsPin(adult.id))
    }

    @Test func remoteOnlyPlaylistShowsMissingCredentialsState() async throws {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        await a.coordinator.flushNow()
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
        await cb.setEnabled(true)
        await b.load()

        let remote = b.remoteOnlyPlaylists
        #expect(remote.map(\.id) == [a.playlist.id])
        #expect(remote.first?.name == a.playlist.name)
        #expect(!SyncMissingCredentials.playlist.isEmpty)
        // Den är inte en riktig spellista här: den kan inte öppnas eller uppdateras.
        #expect(b.playlists.isEmpty)
        #expect(try b.store.playlists().isEmpty)

        // Inloggningen anländer: tillståndet försvinner och spellistan blir användbar.
        try b.credentials.save(.m3u(url: URL(string: "http://x.example/p.m3u")!, epgURL: nil), for: a.playlist.id)
        await b.reconcileSyncedPlaylists()
        #expect(b.remoteOnlyPlaylists.isEmpty)
        #expect(b.playlists.map(\.id) == [a.playlist.id])

        // Standardbygget (ingen koordinator): aldrig någon, även om metadata skulle vara märkt.
        let plain = try makeModel()
        plain.playlistMetadata.applyRemote(id: UUID(), name: "X", kind: .xtream, createdAt: Date(), updatedAt: Date())
        #expect(plain.remoteOnlyPlaylists.isEmpty)
    }

    @Test func defaultBuildSettingsSectionPerformsNoWork() async throws {
        let defaults = freshDefaults()
        let model = try makeModel(defaults: defaults)
        let playlist = try addLocalPlaylist(model)
        model.enter(playlistID: playlist.id)
        #expect(model.syncCoordinator == nil)
        let before = Set(defaults.dictionaryRepresentation().keys)

        let settings = SyncSettingsModel(app: model)
        #expect(settings.isVisible)
        #expect(!settings.isAvailable)
        #expect(!settings.isSyncOn)
        #expect(settings.statusText == nil)
        await settings.setSyncEnabled(true)
        await settings.syncNow()
        await settings.requestKeychain(true)
        await settings.requestKeychain(false)
        await settings.confirmKeychainOff(deleteCloudCopy: true)
        settings.cancelKeychainOff()
        settings.refresh()

        #expect(!settings.isRunning)
        #expect(!settings.isAskingAboutCloudCopy)
        #expect(settings.errorMessage == nil)
        #expect(!settings.keychainOn)
        #expect(model.syncCoordinator == nil)
        #expect(Set(defaults.dictionaryRepresentation().keys) == before)
        #expect(defaults.object(forKey: KeychainSyncPreference.key) == nil)
        #expect(model.remoteOnlyPlaylists.isEmpty)
    }
}

// MARK: - Fjärrraderade spellistor och borttagning av fjärrspellistor

@MainActor
struct RemotePlaylistDeletionTests {
    /// A och B delar moln; B har spellistan fullt lokalt (inloggning + databasrad), A raderar den.
    private func fixture() async throws -> (cloud: InMemoryCloud, a: (model: AppModel, coordinator: SyncCoordinator, playlist: Playlist),
                                            b: AppModel, cb: SyncCoordinator) {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        await a.coordinator.flushNow()
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
        await cb.setEnabled(true)
        try b.credentials.save(xtreamSecret, for: a.playlist.id)
        await b.reconcileSyncedPlaylists()
        #expect(try b.store.playlists().map(\.id) == [a.playlist.id])
        return (cloud, a, b, cb)
    }

    @Test func remotePlaylistDeletionRemovesLocalDataWithoutNewTombstone() async throws {
        let f = try await fixture()
        let id = f.a.playlist.id
        #expect(!f.b.profiles(for: id).isEmpty)
        try await f.a.model.remove(playlistID: id, adultPin: nil)
        await f.a.coordinator.flushNow()
        let versionBefore = f.cloud.currentVersion

        await f.cb.syncNow()
        await f.b.remoteDeletionTask?.value
        await f.b.processRemotePlaylistDeletions()

        #expect(try f.b.store.playlists().isEmpty)
        #expect(try f.b.credentials.load(for: id) == nil)
        #expect(f.b.profiles(for: id).isEmpty)
        #expect(f.b.playlists.isEmpty)
        #expect(f.b.remoteOnlyPlaylists.isEmpty)
        // Gravstenen från A står kvar (bara kvitterad); B skapade ingen egen och pushade inget nytt.
        let entry = try #require(f.b.playlistMetadata.allIncludingTombstones().first { $0.id == id })
        #expect(entry.isDeleted)
        await f.cb.flushNow()
        #expect(f.cloud.currentVersion == versionBefore)
        #expect(f.cb.pendingChangeCount == 0)
    }

    @Test func remotePlaylistDeletionHandledFlagCleared() async throws {
        let model = try makeModel()
        let playlist = try addLocalPlaylist(model)
        _ = model.attachSync(transport: InMemoryCloud().connect(), scheduler: IdleScheduler())
        try model.credentials.save(xtreamSecret, for: playlist.id)
        let deletedAt = Date().addingTimeInterval(60)
        #expect(model.playlistMetadata.applyRemoteTombstone(id: playlist.id, deletedAt: deletedAt))
        #expect(model.playlistMetadata.pendingRemoteDeletions() == [playlist.id])

        await model.processRemotePlaylistDeletions()

        #expect(model.playlistMetadata.pendingRemoteDeletions().isEmpty)
        let entry = try #require(model.playlistMetadata.allIncludingTombstones().first { $0.id == playlist.id })
        #expect(entry.isDeleted)
        #expect(entry.deletedAt == deletedAt)  // oförändrad gravsten, ingen ny
        #expect(try model.store.playlists().isEmpty)
        #expect(try model.credentials.load(for: playlist.id) == nil)
    }

    @Test func remotePlaylistDeletionNoopWithoutPending() async throws {
        // Med koordinator men utan väntande: ingenting rörs.
        let model = try makeModel()
        let playlist = try addLocalPlaylist(model)
        _ = model.attachSync(transport: InMemoryCloud().connect(), scheduler: IdleScheduler())
        try model.credentials.save(xtreamSecret, for: playlist.id)
        await model.processRemotePlaylistDeletions()
        model.handleRemotePlaylistDeletions()
        #expect(model.remoteDeletionTask == nil)
        #expect(try model.store.playlists().count == 1)
        #expect(try model.credentials.load(for: playlist.id) != nil)

        // Standardbygget (ingen koordinator): även en flaggad gravsten lämnas orörd.
        let plain = try makeModel()
        let local = try addLocalPlaylist(plain)
        #expect(plain.playlistMetadata.applyRemoteTombstone(id: local.id, deletedAt: Date().addingTimeInterval(60)))
        await plain.processRemotePlaylistDeletions()
        plain.handleRemotePlaylistDeletions()
        #expect(plain.remoteDeletionTask == nil)
        #expect(try plain.store.playlists().count == 1)
    }

    @Test func remoteOnlyPlaylistCanBeRemovedAndLeavesTombstone() async throws {
        let cloud = InMemoryCloud()
        let a = try await syncedModel(cloud: cloud)
        await a.coordinator.flushNow()
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: IdleScheduler())
        await cb.setEnabled(true)
        let id = a.playlist.id
        #expect(b.remoteOnlyPlaylists.map(\.id) == [id])
        #expect(try b.store.playlists().isEmpty)  // bara i metadata

        try await b.remove(playlistID: id, adultPin: nil)
        await cb.flushNow()

        #expect(b.remoteOnlyPlaylists.isEmpty)
        #expect(b.playlistMetadata.allIncludingTombstones().first { $0.id == id }?.isDeleted == true)
        #expect(cloud.record(for: SyncMapper.playlistID(id))?.deleted == true)
    }
}
