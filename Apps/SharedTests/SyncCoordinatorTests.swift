import Core
import Foundation
import Library
import Personal
import PlaybackCore
import Providers
import ProvidersTestSupport
import Sync
import SyncMapping
import Testing
@testable import IPTVApp

// MARK: - Fakes

/// Manuell tidtagning: inget test sover på riktigt. `advance` kör förfallna åtgärder i tidsordning.
@MainActor
private final class ManualScheduler: SyncScheduling {
    private var items: [Int: (due: TimeInterval, action: @MainActor () -> Void)] = [:]
    private var counter = 0
    private(set) var now: TimeInterval = 0
    /// Alla fördröjningar som begärts, i ordning (för att se backoff).
    private(set) var delays: [TimeInterval] = []
    var pendingCount: Int { items.count }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncTimer {
        let id = counter
        counter += 1
        delays.append(delay)
        items[id] = (now + delay, action)
        return SyncTimer(cancel: { [weak self] in self?.items[id] = nil })
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        while let next = items.filter({ $0.value.due <= now }).min(by: { ($0.value.due, $0.key) < ($1.value.due, $1.key) }) {
            items[next.key] = nil
            next.value.action()
        }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}

/// Transport vars hämtning väntar tills testet öppnar grinden (simulerar en långsam första hämtning).
private final class GatedTransport: SyncTransport {
    let inner: InMemorySyncTransport
    private let gate = Gate()
    init(_ inner: InMemorySyncTransport) { self.inner = inner }

    func open() async { await gate.release() }
    func fetchChanges() async throws -> [SyncRecord] {
        await gate.wait()
        return try await inner.fetchChanges()
    }
    func push(_ records: [SyncRecord]) async throws { try await inner.push(records) }
    var remoteChanges: AsyncStream<Void> { inner.remoteChanges }
}

private final class BundleToken {}

/// Fejkad bakgrundsuppgift: räknar start och slut, så att testet ser att pushen sker inom uppgiften.
@MainActor
private final class RecordingRunner: SyncBackgroundTaskRunning {
    private(set) var started = 0
    private(set) var finished = 0

    func run(_ work: @escaping @MainActor () async -> Void) {
        started += 1
        Task { @MainActor in
            await work()
            finished += 1
        }
    }
}

/// Väntar tills villkoret gäller (högst `timeout`). Inga fasta pauser: villkoret avgör.
@MainActor
private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// En enhet utan AppModel: riktiga lager på en egen UserDefaults-svit, bryggan och en koordinator.
@MainActor
private final class Device {
    let name: String
    let defaults: UserDefaults
    let clock: ManualSyncClock
    let scheduler = ManualScheduler()
    let profiles: UserDefaultsProfileStore
    let metadata: PlaylistMetadataStore
    let subtitles: SubtitleStore?
    let bridge: SyncStoreBridge
    let coordinator: SyncCoordinator

    init(transport: (any SyncTransport)?, name: String = "dev", defaults: UserDefaults = freshDefaults(),
         clock: ManualSyncClock = ManualSyncClock(), subtitles: SubtitleStore? = nil,
         runner: any SyncBackgroundTaskRunning = NoBackgroundTaskRunner()) {
        self.name = name
        self.defaults = defaults
        self.clock = clock
        self.subtitles = subtitles
        profiles = UserDefaultsProfileStore(defaults: defaults, now: { clock.now() })
        metadata = PlaylistMetadataStore(defaults: defaults, now: { clock.now() })
        bridge = SyncStoreBridge(deviceID: name, defaults: defaults, profiles: profiles,
                                 pins: InMemoryProfilePinStore(), metadata: metadata, subtitles: subtitles)
        coordinator = SyncCoordinator(transport: transport, clock: clock, defaults: defaults, bridge: bridge,
                                      scheduler: scheduler, backgroundRunner: runner)
    }

    func tick(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
        scheduler.advance(by: seconds)
    }

    @discardableResult
    func addProfile(_ name: String, playlist: UUID = playlistID, kids: Bool = false, pin: Bool = false) -> Profile {
        let profile = Profile(playlistID: playlist, name: name, avatar: "person", isKids: kids, hasPin: pin,
                              createdAt: clock.now(), updatedAt: clock.now())
        profiles.save(profile)
        coordinator.noteLocalChange(SyncMapper.profileID(profile.id))
        return profile
    }

    func savePlaylist(_ id: UUID = playlistID) {
        let playlist = Playlist(id: id, name: "Lista", kind: .xtream, createdAt: clock.now())
        metadata.save(playlist)
        coordinator.noteLocalChange(SyncMapper.playlistID(id))
    }

    func relaunch(transport: (any SyncTransport)?) -> Device {
        Device(transport: transport, name: name, defaults: defaults, clock: clock, subtitles: subtitles)
    }
}

private let playlistID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

@MainActor
private func makeModel(defaults: UserDefaults = freshDefaults(), subtitles: SubtitleStore? = nil,
                       db: AppDatabase? = nil) throws -> AppModel {
    let database = try db ?? AppDatabase.inMemory()
    return AppModel(store: LibraryStore(db: database), credentials: InMemoryCredentialStore(),
                    http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults, subtitleStore: subtitles)
}

@MainActor
@discardableResult
private func addLocalPlaylist(_ model: AppModel, id: UUID = UUID(), name: String = "Min") throws -> Playlist {
    let playlist = Playlist(id: id, name: name, kind: .xtream)
    try model.store.upsertPlaylist(playlist)
    model.playlistMetadata.save(playlist)
    return playlist
}

private func syncKeys(_ defaults: UserDefaults) -> [String] {
    defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("sync.") }.sorted()
}

private struct LockedFixture {
    let cloud: InMemoryCloud
    let a: AppModel
    let ca: SyncCoordinator
    let b: AppModel
    let cb: SyncCoordinator
    let playlist: Playlist
    let adult: Profile
    let onB: Profile
}

/// A har en PIN-skyddad vuxenprofil; B har synkat den men saknar PIN-hash (låst).
@MainActor
private func lockedFixture() async throws -> LockedFixture {
    let cloud = InMemoryCloud()
    let a = try makeModel()
    let playlist = try addLocalPlaylist(a)
    let ca = a.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
    await ca.setEnabled(true)
    let adult = try a.addProfile(playlistID: playlist.id, name: "Vuxen", avatar: "star.fill", pin: "1234")
    await ca.flushNow()
    let b = try makeModel()
    let cb = b.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
    await cb.setEnabled(true)
    let onB = try #require(b.profiles(for: playlist.id).first { $0.id == adult.id })
    #expect(b.profileNeedsPin(adult.id))
    return LockedFixture(cloud: cloud, a: a, ca: ca, b: b, cb: cb, playlist: playlist, adult: adult, onB: onB)
}

// MARK: - Tester

@MainActor
struct SyncCoordinatorTests {
    @Test func unavailableBuildIsCompleteNoOp() async throws {
        let d = Device(transport: nil)
        #expect(d.coordinator.status == .unavailable)
        #expect(!d.coordinator.isAvailable)

        await d.coordinator.setEnabled(true)
        d.coordinator.start()
        d.coordinator.noteLocalChange(SyncMapper.profileID(UUID()))
        d.coordinator.profileWillBeDeleted(UUID())
        d.coordinator.playlistWillBeDeleted(UUID())
        d.coordinator.clearPinMissing(UUID())
        d.coordinator.sceneDidBecomeActive()
        d.coordinator.sceneDidEnterBackground()
        d.coordinator.requestImmediatePush()
        await d.coordinator.syncNow()
        await d.coordinator.flushNow()
        await d.coordinator.waitForInitialPull(timeout: 10)

        #expect(d.coordinator.status == .unavailable)
        #expect(!d.coordinator.isEnabled)
        #expect(!d.coordinator.isAwaitingInitialPull)
        #expect(d.coordinator.pendingChangeCount == 0)
        #expect(d.scheduler.delays.isEmpty)
        #expect(syncKeys(d.defaults).isEmpty)

        // Hela appen: utan koppling finns ingen koordinator, och en standardprofil skapas direkt som förut.
        let model = try makeModel()
        #expect(model.syncCoordinator == nil)
        try addLocalPlaylist(model)
        await model.load()
        let playlist = try #require(model.playlists.first)
        #expect(model.profiles(for: playlist.id).count == 1)
        #expect(syncKeys(model.defaults).isEmpty)
        model.attachSyncIfAvailable()
        #expect(model.syncCoordinator == nil)
    }

    @Test func backgroundPushRunsInsideBackgroundTask() async throws {
        let cloud = InMemoryCloud()
        let transport = cloud.connect()
        let runner = RecordingRunner()
        let d = Device(transport: transport, runner: runner)
        await d.coordinator.setEnabled(true)

        // Inget väntar: ingen bakgrundsuppgift begärs.
        d.coordinator.sceneDidEnterBackground()
        #expect(runner.started == 0)

        let anna = d.addProfile("Anna")
        d.coordinator.sceneDidEnterBackground()
        #expect(runner.started == 1)
        #expect(await waitUntil { runner.finished == 1 })
        #expect(transport.pushCount == 1)
        #expect(cloud.record(for: SyncMapper.profileID(anna.id))?.deleted == false)

        // Utan transport (standardbygget) används körningen aldrig.
        let off = Device(transport: nil, runner: runner)
        off.coordinator.sceneDidEnterBackground()
        #expect(runner.started == 1)
    }

    @Test func makeSyncTransportNotCalledWhenUnavailable() throws {
        // Testvärdens Info.plist har SyncEnabled = NO: transporten (och därmed CloudKit) skapas aldrig.
        let model = try makeModel()
        var calls = 0
        model.attachSyncIfAvailable(bundle: Bundle(for: BundleToken.self), makeTransport: {
            calls += 1
            return nil
        })
        #expect(calls == 0)
        #expect(model.syncCoordinator == nil)
    }

    @Test func syncAvailabilityFalseWithoutInfoPlistFlag() {
        // Testpaketets Info.plist har ingen SyncEnabled.
        #expect(!SyncAvailability.isAvailable(bundle: Bundle(for: BundleToken.self)))
        #expect(!SyncAvailability.isAvailable(infoValue: nil))
        #expect(!SyncAvailability.isAvailable(infoValue: "NO"))
        #expect(!SyncAvailability.isAvailable(infoValue: ""))
        #expect(!SyncAvailability.isAvailable(infoValue: "$(ICLOUD_SYNC_ENABLED)"))
        #expect(!SyncAvailability.isAvailable(infoValue: 1))
        #expect(SyncAvailability.isAvailable(infoValue: "YES"))
    }

    @Test func localChangesAreThrottledAndPushed() async throws {
        let cloud = InMemoryCloud()
        let transport = cloud.connect()
        let d = Device(transport: transport)
        await d.coordinator.setEnabled(true)
        #expect(transport.pushCount == 0)

        let first = d.addProfile("Anna")
        #expect(d.coordinator.pendingChangeCount == 1)
        #expect(transport.pushCount == 0)
        d.scheduler.advance(by: 0)
        await d.coordinator.settle()
        #expect(transport.pushCount == 1)
        #expect(cloud.record(for: SyncMapper.profileID(first.id))?.deleted == false)
        #expect(d.coordinator.pendingChangeCount == 0)

        // Nästa ändring väntar ut resten av minuten; fler ändringar delar samma push.
        d.tick(10)
        d.addProfile("Bo")
        d.addProfile("Cia")
        d.tick(49)
        await d.coordinator.settle()
        #expect(transport.pushCount == 1)
        d.tick(1)
        await d.coordinator.settle()
        #expect(transport.pushCount == 2)
        #expect(cloud.allRecords.filter { $0.id.kind == .profile }.count == 3)

        // Direkt vid bakgrund eller när spelaren stängs.
        d.addProfile("Dan")
        #expect(transport.pushCount == 2)
        await d.coordinator.flushNow()
        #expect(transport.pushCount == 3)
        #expect(d.coordinator.pendingChangeCount == 0)
    }

    @Test func remoteChangeAppliesAndUpdatesUI() async throws {
        let cloud = InMemoryCloud()
        let a = Device(transport: cloud.connect(), name: "A")
        let b = Device(transport: cloud.connect(), name: "B")
        await a.coordinator.setEnabled(true)
        await b.coordinator.setEnabled(true)
        let revision = b.coordinator.appliedRevision

        let profile = a.addProfile("Anna", kids: true)
        await a.coordinator.flushNow()

        // B får en notis och hämtar utan att något anropas.
        #expect(await waitUntil { b.profiles.allProfiles().count == 1 })
        let received = try #require(b.profiles.allProfiles().first)
        #expect(received.id == profile.id)
        #expect(received.name == "Anna")
        #expect(received.isKids)
        // Fjärrens tidsstämpel behålls, den bumpas inte till "nu".
        #expect(received.updatedAt == profile.updatedAt)
        #expect(b.coordinator.appliedRevision > revision)
    }

    @Test func failedPushRetriesWithBackoff() async throws {
        let cloud = InMemoryCloud()
        let transport = cloud.connect()
        let d = Device(transport: transport)
        await d.coordinator.setEnabled(true)
        transport.failNextPushes(2)

        let profile = d.addProfile("Anna")
        d.scheduler.advance(by: 0)
        await d.coordinator.settle()
        #expect(transport.pushCount == 1)
        #expect(d.coordinator.status == .failed(.other))
        #expect(d.coordinator.pendingChangeCount == 1)
        #expect(d.scheduler.delays.last == 5)

        d.tick(5)
        await d.coordinator.settle()
        #expect(transport.pushCount == 2)
        #expect(d.coordinator.status == .failed(.other))
        #expect(d.scheduler.delays.last == 10)

        d.tick(9)
        await d.coordinator.settle()
        #expect(transport.pushCount == 2)
        d.tick(1)
        await d.coordinator.settle()
        #expect(transport.pushCount == 3)
        #expect(d.coordinator.status == .idle(lastSync: d.clock.now()))
        #expect(d.coordinator.pendingChangeCount == 0)
        #expect(cloud.record(for: SyncMapper.profileID(profile.id)) != nil)
    }

    @Test func noDuplicateDefaultProfileOnFreshDeviceWithSyncedProfiles() async throws {
        let cloud = InMemoryCloud()
        // Enhet A har spellistan och profilen "Anna".
        let a = try makeModel()
        let playlist = try addLocalPlaylist(a)
        let ca = a.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await ca.setEnabled(true)
        try a.addProfile(playlistID: playlist.id, name: "Anna", avatar: "star.fill")
        await ca.flushNow()

        // Enhet B har samma spellista men inga profiler, synk är på och första hämtningen är långsam.
        let defaults = freshDefaults()
        defaults.set(true, forKey: SyncCoordinator.enabledKey)
        let b = try makeModel(defaults: defaults)
        try addLocalPlaylist(b, id: playlist.id)
        let gated = GatedTransport(cloud.connect())
        let scheduler = ManualScheduler()
        let cb = b.attachSync(transport: gated, scheduler: scheduler)

        let loading = Task { await b.load() }
        #expect(await waitUntil { scheduler.pendingCount > 0 })
        #expect(b.profiles(for: playlist.id).isEmpty)
        #expect(cb.isAwaitingInitialPull)

        await gated.open()
        await loading.value
        #expect(b.profiles(for: playlist.id).map(\.name) == ["Anna"])
        #expect(cb.initialPullDone)
    }

    @Test func defaultProfileCreatedAfterTimeoutIfCloudEmpty() async throws {
        let cloud = InMemoryCloud()
        let defaults = freshDefaults()
        defaults.set(true, forKey: SyncCoordinator.enabledKey)
        let b = try makeModel(defaults: defaults)
        let playlist = try addLocalPlaylist(b)
        let gated = GatedTransport(cloud.connect())
        let scheduler = ManualScheduler()
        let cb = b.attachSync(transport: gated, scheduler: scheduler)

        let loading = Task { await b.load() }
        #expect(await waitUntil { scheduler.pendingCount > 0 })
        #expect(b.profiles(for: playlist.id).isEmpty)

        scheduler.advance(by: 10)
        await loading.value
        #expect(b.profiles(for: playlist.id).count == 1)
        #expect(!cb.initialPullDone)
        // Väntan är förbrukad: nästa spellista väntar inte igen.
        #expect(!cb.isAwaitingInitialPull)
        await gated.open()
    }

    @Test func disablingStopsSyncWithoutDeletingData() async throws {
        let cloud = InMemoryCloud()
        let transport = cloud.connect()
        let d = Device(transport: transport)
        await d.coordinator.setEnabled(true)
        let anna = d.addProfile("Anna")
        await d.coordinator.flushNow()
        #expect(cloud.record(for: SyncMapper.profileID(anna.id)) != nil)

        await d.coordinator.setEnabled(false)
        #expect(d.coordinator.status == .off)
        #expect(!d.coordinator.isEnabled)
        #expect(d.profiles.allProfiles().count == 1)
        #expect(cloud.record(for: SyncMapper.profileID(anna.id))?.deleted == false)

        let pushes = transport.pushCount
        let fetches = transport.fetchCount
        let bo = d.addProfile("Bo")
        d.coordinator.sceneDidBecomeActive()
        d.coordinator.sceneDidEnterBackground()
        await d.coordinator.syncNow()
        #expect(d.coordinator.pendingChangeCount == 0)
        #expect(transport.pushCount == pushes)
        #expect(transport.fetchCount == fetches)
        #expect(cloud.record(for: SyncMapper.profileID(bo.id)) == nil)

        // Valet överlever en omstart.
        let relaunched = d.relaunch(transport: cloud.connect())
        #expect(!relaunched.coordinator.isEnabled)
        #expect(relaunched.coordinator.status == .off)

        // Slås synk på igen laddas det som ändrats under uppehållet upp.
        await d.coordinator.setEnabled(true)
        #expect(cloud.record(for: SyncMapper.profileID(bo.id))?.deleted == false)
    }

    @Test func echoOfRemoteApplyIsNotPushedBack() async throws {
        let cloud = InMemoryCloud()
        let aTransport = cloud.connect()
        let bTransport = cloud.connect()
        let a = Device(transport: aTransport, name: "A")
        let b = Device(transport: bTransport, name: "B")
        await b.coordinator.setEnabled(true)
        await a.coordinator.setEnabled(true)

        let profile = a.addProfile("Anna")
        let item = ItemRef(kind: .movie, providerID: "m1")
        let aClock = a.clock
        let personal = UserDefaultsPersonalStore(defaults: a.defaults, key: ProfileKeys.personal(profile.id),
                                                 now: { aClock.now() })
        _ = personal.toggleMyList(item)
        a.coordinator.noteLocalChange(SyncMapper.watchlistID(profile: profile.id, item: item))
        let progress = WatchProgress(key: ProgressKey(playlistID: playlistID, kind: .movie, providerID: "m1"),
                                     position: 600, duration: 6000, watched: false, updatedAt: a.clock.now())
        UserDefaultsUserStateStore(defaults: a.defaults, key: ProfileKeys.progress(profile.id)).save(progress)
        a.coordinator.noteLocalChange(SyncMapper.progressID(profile: profile.id, key: progress.key))
        var settings = PlaybackSettings()
        settings.previewsEnabled = false
        settings.touch(now: a.clock.now())
        settings.save(to: a.defaults, key: ProfileKeys.settings(profile.id))
        a.coordinator.noteLocalChange(SyncMapper.settingsID(profile.id))
        await a.coordinator.flushNow()
        let version = cloud.currentVersion

        await b.coordinator.syncNow()
        #expect(b.profiles.allProfiles().map(\.id) == [profile.id])
        let bPersonal = UserDefaultsPersonalStore(defaults: b.defaults, key: ProfileKeys.personal(profile.id))
        #expect(bPersonal.myList() == [item])
        #expect(UserDefaultsUserStateStore(defaults: b.defaults, key: ProfileKeys.progress(profile.id))
            .progress(for: progress.key) == progress)
        #expect(PlaybackSettings.load(from: b.defaults, key: ProfileKeys.settings(profile.id)) == settings)

        // Inget skickas tillbaka: ingen push, inga smutsiga poster, molnet oförändrat.
        #expect(bTransport.pushCount == 0)
        #expect(b.coordinator.pendingChangeCount == 0)
        #expect(cloud.currentVersion == version)
    }

    @Test func deletedProfileTombstonePersistedAcrossRelaunch() async throws {
        let cloud = InMemoryCloud()
        let a = Device(transport: cloud.connect(), name: "A")
        await a.coordinator.setEnabled(true)
        let profile = a.addProfile("Anna")
        await a.coordinator.flushNow()
        #expect(cloud.record(for: SyncMapper.profileID(profile.id))?.deleted == false)

        // Användaren raderar profilen; appen dör innan raderingen hunnit pushas.
        a.clock.advance(by: 100)
        a.coordinator.profileWillBeDeleted(profile.id)
        a.profiles.delete(id: profile.id)

        // Ny start: nya objekt på samma lagring, ny transporthandtag (läsmarkör 0 levererar den gamla levande profilen).
        let relaunched = a.relaunch(transport: cloud.connect())
        #expect(relaunched.coordinator.pendingChangeCount > 0)
        await relaunched.coordinator.syncNow()

        #expect(relaunched.profiles.allProfiles().isEmpty)
        #expect(cloud.record(for: SyncMapper.profileID(profile.id))?.deleted == true)
    }

    @Test func remoteProfileWithHasPinButNoLocalHash() async throws {
        let cloud = InMemoryCloud()
        let a = Device(transport: cloud.connect(), name: "A")
        let bTransport = cloud.connect()
        let b = Device(transport: bTransport, name: "B")
        await b.coordinator.setEnabled(true)
        await a.coordinator.setEnabled(true)

        let profile = a.addProfile("Anna", kids: true, pin: true)
        await a.coordinator.flushNow()
        let version = cloud.currentVersion
        await b.coordinator.syncNow()

        // B saknar PIN-hashen: profilen låser ingen ute, men är fortfarande en barnprofil...
        let stored = try #require(b.profiles.allProfiles().first)
        #expect(!stored.hasPin)
        #expect(stored.isKids)
        #expect(stored.updatedAt == profile.updatedAt)
        // ...och rapporteras som PIN-skyddad, så att inget skickas tillbaka (ingen pingpong).
        #expect(b.bridge.loadState().profiles[profile.id]?.hasPin == true)
        #expect(bTransport.pushCount == 0)
        #expect(cloud.currentVersion == version)

        // En ändring på B (namn) tar inte bort PIN-skyddet på de andra enheterna.
        b.clock.advance(by: 10)
        var renamed = stored
        renamed.name = "Bo"
        b.profiles.save(renamed)
        b.coordinator.noteLocalChange(SyncMapper.profileID(profile.id))
        await b.coordinator.flushNow()
        await a.coordinator.syncNow()
        let onA = try #require(a.profiles.allProfiles().first)
        #expect(onA.name == "Bo")
        #expect(onA.hasPin)
        #expect(onA.isKids)

        // När PIN-hashen finns lokalt (Task 7) hävs låset och profilen får hasPin lokalt.
        b.coordinator.clearPinMissing(profile.id)
        #expect(!b.coordinator.profileNeedsPin(profile.id))
        #expect(b.profiles.allProfiles().first?.hasPin == true)
    }

    @Test func twoAppModelsSyncProfilesViaInMemoryTransport() async throws {
        let cloud = InMemoryCloud()
        let a = try makeModel()
        let playlist = try addLocalPlaylist(a)
        await a.load()
        let ca = a.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await ca.setEnabled(true)
        let kid = try a.addProfile(playlistID: playlist.id, name: "Kid", avatar: "star.fill", isKids: true)
        await ca.flushNow()

        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        let revision = b.profilesRevision
        await cb.setEnabled(true)
        #expect(b.profiles(for: playlist.id).count == 2)
        #expect(b.profiles(for: playlist.id).first { $0.id == kid.id }?.isKids == true)
        #expect(b.profilesRevision > revision)
        // Spellistan kommer som metadata utan inloggning.
        #expect(b.playlistMetadata.all().first { $0.id == playlist.id }?.fromRemote == true)

        // Namnbyte på B når A.
        let kidOnB = try #require(b.profiles(for: playlist.id).first { $0.id == kid.id })
        try b.updateProfile(Profile(id: kidOnB.id, playlistID: playlist.id, name: "Junior", avatar: kidOnB.avatar,
                                    isKids: true))
        await cb.flushNow()
        await ca.syncNow()
        #expect(a.profiles(for: playlist.id).first { $0.id == kid.id }?.name == "Junior")

        // Radering på A når B.
        let kidOnA = try #require(a.profiles(for: playlist.id).first { $0.id == kid.id })
        try a.deleteProfile(kidOnA)
        await ca.flushNow()
        await cb.syncNow()
        #expect(!b.profiles(for: playlist.id).contains { $0.id == kid.id })
        #expect(!a.profiles(for: playlist.id).contains { $0.id == kid.id })
    }

    @Test func playlistRemovalPropagatesAsTombstone() async throws {
        let cloud = InMemoryCloud()
        let a = try makeModel()
        let playlist = try addLocalPlaylist(a)
        await a.load()
        let ca = a.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await ca.setEnabled(true)
        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await cb.setEnabled(true)
        #expect(b.profiles(for: playlist.id).count == 1)

        await a.remove(playlist.id)
        await ca.flushNow()
        #expect(cloud.record(for: SyncMapper.playlistID(playlist.id))?.deleted == true)

        await cb.syncNow()
        #expect(b.profiles(for: playlist.id).isEmpty)
        #expect(b.playlistMetadata.pendingRemoteDeletions() == [playlist.id])
        // En ny start på A återupplivar ingenting.
        await a.load()
        #expect(a.profiles(for: playlist.id).isEmpty)
    }

    @Test func orphanCleanupNeverPushesDeletion() async throws {
        let cloud = InMemoryCloud()
        let model = try makeModel()
        // Metadata utan databasrad och utan inloggning: föräldralös, städas bort lokalt.
        let orphan = Playlist(name: "Orphan", kind: .xtream)
        model.playlistMetadata.save(orphan)
        let coordinator = model.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())

        await model.load()
        #expect(model.playlistMetadata.allIncludingTombstones().isEmpty)
        await coordinator.setEnabled(true)
        await coordinator.syncNow()

        #expect(cloud.allRecords.allSatisfy { !$0.deleted })
        #expect(cloud.record(for: SyncMapper.playlistID(orphan.id)) == nil)
    }

    @Test func legacyItemsStampedOnPushNotRewritten() async throws {
        let cloud = InMemoryCloud()
        let d = Device(transport: cloud.connect())
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let legacy = Profile(playlistID: playlistID, name: "Gammal", avatar: "person", createdAt: created,
                             updatedAt: .distantPast)
        d.profiles.save(legacy)
        // Äldre Min lista-blob (före tidsstämplar) och orörda respektive ändrade inställningar utan tidsstämpel.
        let blob = Data(#"{"list":[{"kind":"movie","providerID":"m1"}]}"#.utf8)
        d.defaults.set(blob, forKey: ProfileKeys.personal(legacy.id))
        var settings = PlaybackSettings()
        settings.previewsEnabled = false
        settings.save(to: d.defaults, key: ProfileKeys.settings(legacy.id))
        let personalBefore = d.defaults.data(forKey: ProfileKeys.personal(legacy.id))
        let settingsBefore = d.defaults.data(forKey: ProfileKeys.settings(legacy.id))

        await d.coordinator.setEnabled(true)
        await d.coordinator.syncNow()

        let item = ItemRef(kind: .movie, providerID: "m1")
        #expect(cloud.record(for: SyncMapper.profileID(legacy.id))?.updatedAt == created)
        #expect(cloud.record(for: SyncMapper.watchlistID(profile: legacy.id, item: item))?.updatedAt == created)
        #expect(cloud.record(for: SyncMapper.settingsID(legacy.id))?.updatedAt == created)

        // Lokala data är orörda.
        #expect(d.profiles.allProfiles().first?.updatedAt == .distantPast)
        #expect(d.defaults.data(forKey: ProfileKeys.personal(legacy.id)) == personalBefore)
        #expect(d.defaults.data(forKey: ProfileKeys.settings(legacy.id)) == settingsBefore)
        #expect(PlaybackSettings.load(from: d.defaults, key: ProfileKeys.settings(legacy.id)).updatedAt == .distantPast)
    }

    @Test func subtitleOffsetAppliedAfterPlaylistArrives() async throws {
        let cloud = InMemoryCloud()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-offset-tests-\(UUID().uuidString)", isDirectory: true)
        let dbA = try AppDatabase.inMemory()
        let dbB = try AppDatabase.inMemory()
        let subsA = SubtitleStore(db: dbA, directory: directory.appendingPathComponent("a", isDirectory: true))
        let subsB = SubtitleStore(db: dbB, directory: directory.appendingPathComponent("b", isDirectory: true))
        let a = Device(transport: cloud.connect(), name: "A", subtitles: subsA)
        let b = Device(transport: cloud.connect(), name: "B", subtitles: subsB)
        await b.coordinator.setEnabled(true)
        await a.coordinator.setEnabled(true)

        // A har spellistan (i databasen), profilen och en förskjutning.
        let playlist = Playlist(id: playlistID, name: "Lista", kind: .xtream, createdAt: a.clock.now())
        try LibraryStore(db: dbA).upsertPlaylist(playlist)
        let profile = a.addProfile("Anna")
        let key = SubtitleKey(profileID: profile.id, playlistID: playlistID, kind: .movie, providerID: "m1")
        try subsA.setOffset(2.5, for: key, now: a.clock.now())
        a.coordinator.noteLocalChange(SyncMapper.subtitleOffsetID(
            SubtitleOffsetKey(profileID: profile.id, playlistID: playlistID, kind: .movie, providerID: "m1")))
        await a.coordinator.flushNow()

        // B saknar spellistan i databasen: förskjutningen väntar.
        await b.coordinator.syncNow()
        #expect(b.profiles.allProfiles().count == 1)
        #expect(try subsB.offsets(profileID: profile.id).isEmpty)
        #expect(b.bridge.pendingOffsetCount == 1)

        // Spellistan kommer in i databasen: nästa försök sparar förskjutningen med fjärrens tid.
        try LibraryStore(db: dbB).upsertPlaylist(playlist)
        b.bridge.retryPendingOffsets()
        let offsets = try subsB.offsets(profileID: profile.id)
        #expect(offsets.count == 1)
        #expect(offsets.first?.offsetMs == 2500)
        #expect(offsets.first?.updatedAt == a.clock.now())
        #expect(b.bridge.pendingOffsetCount == 0)
    }

    @Test func syncedPinProtectedProfileCannotBeEnteredWithoutLocalPin() async throws {
        let cloud = InMemoryCloud()
        let a = try makeModel()
        let playlist = try addLocalPlaylist(a)
        let ca = a.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await ca.setEnabled(true)
        let adult = try a.addProfile(playlistID: playlist.id, name: "Vuxen", avatar: "star.fill", pin: "1234")
        await ca.flushNow()

        let b = try makeModel()
        let cb = b.attachSync(transport: cloud.connect(), scheduler: ManualScheduler())
        await cb.setEnabled(true)
        let onB = try #require(b.profiles(for: playlist.id).first { $0.id == adult.id })
        #expect(b.profileNeedsPin(adult.id))

        // Varken val eller att öppna spellistan släpper in utan lokal PIN.
        await #expect(throws: ProfileError.pinRequiredOnThisDevice) { try await b.select(profile: onB, pin: nil) }
        await #expect(throws: ProfileError.pinRequiredOnThisDevice) { try await b.select(profile: onB, pin: "1234") }
        b.enter(playlistID: playlist.id)
        #expect(b.activeProfile == nil)
        #expect(throws: ProfileError.pinRequiredOnThisDevice) {
            try b.updateProfile(onB, pin: .remove)
        }
        #expect(b.profileNeedsPin(adult.id))
    }

    @Test func lockedProfileCannotBeUnlockedBySettingPin() async throws {
        let f = try await lockedFixture()
        #expect(throws: ProfileError.pinRequiredOnThisDevice) {
            try f.b.updateProfile(f.onB, pin: .set("4321"))
        }
        #expect(f.b.profileNeedsPin(f.onB.id))
        await #expect(throws: ProfileError.pinRequiredOnThisDevice) { try await f.b.select(profile: f.onB, pin: "4321") }
        #expect(f.b.activeProfile == nil)
    }

    @Test func lockedProfileCannotBeRenamedConvertedOrDeleted() async throws {
        let f = try await lockedFixture()
        var renamed = f.onB
        renamed.name = "Nytt"
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try f.b.updateProfile(renamed) }
        var converted = f.onB
        converted.isKids = true
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try f.b.updateProfile(converted) }
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try f.b.updateProfile(f.onB, pin: .remove) }
        #expect(throws: ProfileError.pinRequiredOnThisDevice) { try f.b.deleteProfile(f.onB) }
        #expect(f.b.profiles(for: f.playlist.id).contains { $0.id == f.onB.id && $0.name == f.onB.name && !$0.isKids })
        // Ingen raderingsgravsten har uppstått.
        await f.cb.flushNow()
        #expect(f.cloud.record(for: SyncMapper.profileID(f.onB.id))?.deleted == false)
    }

    @Test func clearPinMissingUnlocksAndSetsHasPin() async throws {
        let f = try await lockedFixture()
        #expect(f.b.profiles(for: f.playlist.id).first { $0.id == f.onB.id }?.hasPin == false)
        f.cb.clearPinMissing(f.onB.id)
        #expect(!f.b.profileNeedsPin(f.onB.id))
        #expect(f.b.profiles(for: f.playlist.id).first { $0.id == f.onB.id }?.hasPin == true)
    }

    @Test func remoteHasPinFalseClearsLock() async throws {
        let f = try await lockedFixture()
        // PIN:en tas bort på enhet A.
        try f.a.updateProfile(f.adult, pin: .remove, currentPin: "1234", adultPin: "1234")
        await f.ca.flushNow()
        await f.cb.syncNow()
        #expect(!f.b.profileNeedsPin(f.onB.id))
        #expect(f.b.profiles(for: f.playlist.id).first { $0.id == f.onB.id }?.hasPin == false)
        try await f.b.select(profile: f.onB, pin: nil)
        #expect(f.b.activeProfile?.profile.id == f.onB.id)
    }

    @Test func pinMissingProfileStaysLockedAfterRelaunch() async throws {
        let cloud = InMemoryCloud()
        let a = Device(transport: cloud.connect(), name: "A")
        let b = Device(transport: cloud.connect(), name: "B")
        await b.coordinator.setEnabled(true)
        await a.coordinator.setEnabled(true)
        let profile = a.addProfile("Vuxen", pin: true)
        await a.coordinator.flushNow()
        await b.coordinator.syncNow()
        #expect(b.coordinator.profileNeedsPin(profile.id))

        let relaunched = b.relaunch(transport: cloud.connect())
        #expect(relaunched.coordinator.profileNeedsPin(profile.id))
        await relaunched.coordinator.syncNow()
        #expect(relaunched.coordinator.profileNeedsPin(profile.id))
        // Synk av/på (ingen PIN-hash lokalt) låser inte upp.
        #expect(!(relaunched.profiles.allProfiles().first?.hasPin ?? true))
    }

    @Test func initialPullWaitSkippedWhenProfilesExist() async throws {
        let cloud = InMemoryCloud()
        let defaults = freshDefaults()
        defaults.set(true, forKey: SyncCoordinator.enabledKey)
        let b = try makeModel(defaults: defaults)
        let playlist = try addLocalPlaylist(b)
        b.profileStore.save(Profile(playlistID: playlist.id, name: "Finns", avatar: "person"))
        let gated = GatedTransport(cloud.connect())
        let scheduler = ManualScheduler()
        b.attachSync(transport: gated, scheduler: scheduler)

        // Grinden är stängd och tiden står still: om load väntade skulle det hänga.
        await b.load()
        #expect(b.profiles(for: playlist.id).count == 1)
        #expect(scheduler.pendingCount == 0)
        await gated.open()
    }
}
