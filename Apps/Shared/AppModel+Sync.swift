import Foundation
import CloudSync
import Library
import Personal
import PlaybackCore
import SwiftUI
import Sync
import SyncMapping

/// Kopplingen mellan appen och synken. Allt här är overksamt så länge `syncCoordinator` är `nil`, vilket är
/// fallet i standardbygget (ingen transport, ingen CloudKit).
extension AppModel {
    /// Kopplar in synk med en transport. Anropas av `live()` bara när bygget har synk (`SyncAvailability`), och av
    /// tester. Synken är fortfarande AV tills användaren slår på den (`SyncCoordinator.setEnabled`).
    @discardableResult
    func attachSync(transport: (any SyncTransport)?, clock: any SyncClock = SystemSyncClock(),
                    scheduler: (any SyncScheduling)? = nil,
                    timing: SyncCoordinator.Timing = SyncCoordinator.Timing(),
                    backgroundRunner: any SyncBackgroundTaskRunning = PlatformBackgroundTaskRunner()) -> SyncCoordinator {
        let bridge = SyncStoreBridge(deviceID: Self.syncDeviceID(defaults: defaults), defaults: defaults,
                                     profiles: profileStore, pins: pins, metadata: playlistMetadata,
                                     subtitles: subtitleStore)
        bridge.hooks.personalStore = { [weak self] id in self?.sessions[id]?.personalBacking }
        bridge.hooks.progressStore = { [weak self] id in self?.sessions[id]?.progressBacking }
        bridge.hooks.applySettings = { [weak self] id, settings in
            guard let session = self?.sessions[id] else { return false }
            session.applySynced(settings: settings)
            return true
        }
        bridge.hooks.removeProfile = { [weak self] id in
            self?.purgeProfile(id, userInitiated: false)
            self?.profilesRevision += 1
        }
        bridge.hooks.profileApplied = { [weak self] profile in
            self?.sessions[profile.id]?.update(profile)
            self?.profilesRevision += 1
        }
        bridge.hooks.didApply = { [weak self] changes in self?.syncDidApply(changes) }
        let coordinator = SyncCoordinator(transport: transport, clock: clock, defaults: defaults, bridge: bridge,
                                          scheduler: scheduler, timing: timing, backgroundRunner: backgroundRunner)
        syncCoordinator = coordinator
        for session in sessions.values { installSyncHandler(on: session) }
        return coordinator
    }

    /// Kopplar in synk om bygget har den (`SyncEnabled`) och en transport finns. I standardbygget händer ingenting:
    /// `makeTransport` anropas aldrig, så ingen CloudKit-kod körs.
    func attachSyncIfAvailable(bundle: Bundle = .main,
                               makeTransport: () -> (any SyncTransport)? = { AppModel.makeSyncTransport() }) {
        guard SyncAvailability.isAvailable(bundle: bundle), let transport = makeTransport() else { return }
        attachSync(transport: transport)
    }

    /// CloudKit-transporten. Nås bara från synkbyggen (`SyncEnabled == YES`, betalt konto, entitlements). Att skapa
    /// den rör inte CloudKit; container och motor skapas först vid första hämtningen, efter kontrollen av iCloud-kontot.
    nonisolated static func makeSyncTransport(bundle: Bundle = .main) -> (any SyncTransport)? {
        CloudKitTransport(containerIdentifier: CloudKitConfiguration.containerIdentifier(bundle: bundle),
                          stateDirectory: CloudKitConfiguration.defaultStateDirectory())
    }

    /// Enhetens synk-id (skapas första gången synk kopplas in; används som deterministisk tie-break).
    nonisolated static func syncDeviceID(defaults: UserDefaults) -> String {
        let key = "sync.deviceID.v1"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let created = String(UUID().uuidString.lowercased().prefix(8))
        defaults.set(created, forKey: key)
        return created
    }

    /// Meddelar synken om en lokal ändring. `id` byggs bara när synk finns.
    func noteSyncChange(_ id: @autoclosure () -> SyncRecordID) {
        guard let sync = syncCoordinator else { return }
        sync.noteLocalChange(id())
    }

    func installSyncHandler(on session: ProfileSession) {
        guard let sync = syncCoordinator else { return }
        session.changeNotifier.setHandler { [weak sync] id in
            Task { @MainActor in sync?.noteLocalChange(id) }
        }
    }

    func syncScenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: syncCoordinator?.sceneDidBecomeActive()
        case .background: syncCoordinator?.sceneDidEnterBackground()
        default: break
        }
    }

    /// Fjärrändringar har skrivits till lagren: vyerna läser om.
    func syncDidApply(_ changes: SyncChangeSet) {
        if !changes.profiles.isEmpty || !changes.removedProfiles.isEmpty { profilesRevision += 1 }
        if !changes.personal.isEmpty || !changes.removedProfiles.isEmpty { personalRevision += 1 }
        if !changes.removedPlaylists.isEmpty { handleRemotePlaylistDeletions() }
    }

    /// Fail-closed: profilen kom från synken som PIN-skyddad men PIN-hashen finns inte på den här enheten. Den är
    /// helt låst (kan inte väljas, redigeras, få PIN eller raderas) tills hashen anländer (Task 7) eller PIN:en
    /// tas bort på en annan enhet. UI visar den som låst.
    func profileNeedsPin(_ id: UUID) -> Bool {
        syncCoordinator?.profileNeedsPin(id) ?? false
    }

    /// Spellistor som raderats på en annan enhet väntar på lokal städning (katalog, nyckelring). Själva städningen
    /// görs av en senare uppgift; här listas bara id:na.
    func handleRemotePlaylistDeletions() {
        _ = playlistMetadata.pendingRemoteDeletions()
    }
}
