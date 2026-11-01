import Core
import Foundation
import Library
import Personal
import Secrets

/// Fel vid växling av iCloud Keychain-synk. Fast beskrivning, aldrig en hemlighet.
enum KeychainSyncError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable
    var description: String { "iCloud Keychain-synk är inte tillgänglig i det här bygget" }
}

/// Valfri iCloud Keychain-synk av inloggningar och PIN-hashar. Allt här är overksamt i standardbygget
/// (`keychainSyncAvailable == false`): inga synkroniserbara poster skapas eller läses någonsin.
extension AppModel {
    /// Är synkade Keychain-poster i bruk just nu? Bygget har synk och användaren har slagit på "iCloud Keychain".
    var keychainSyncActive: Bool {
        keychainSyncAvailable && KeychainSyncPreference(defaults: defaults).isEnabled
    }

    /// Slår iCloud Keychain-synk på eller av. Lagren läser läget vid varje anrop, så inga instanser byts ut och
    /// samtidiga läsningar fungerar hela tiden (läsning i synkat läge hittar både lokala och synkade poster).
    ///
    /// På: sparar inställningen först, flyttar sedan varje lokal post (inloggningar, därefter PIN-hashar) till en
    /// synkad: skriv, verifiera, ta bort den lokala. Misslyckas flytten står inställningen kvar på "på" (inga
    /// poster blir oläsbara) och anropet kan göras om.
    ///
    /// Av: skriver först verifierade lokala kopior och sparar därefter inställningen. Med `deleteCloudCopy` raderas
    /// även de synkade kopiorna. VARNING: det raderar dem på ALLA användarens enheter; standard är att lämna dem.
    func setKeychainSyncEnabled(_ on: Bool, deleteCloudCopy: Bool = false) async throws {
        guard keychainSyncAvailable else {
            if on { throw KeychainSyncError.unavailable }
            return
        }
        let preference = KeychainSyncPreference(defaults: defaults)
        let stores: [any KeychainSyncMigrating] = [credentials as? any KeychainSyncMigrating,
                                                   pins as? any KeychainSyncMigrating].compactMap { $0 }
        if on {
            preference.isEnabled = true
            try await offMain(honorsCancellation: false) {
                for store in stores { try store.migrateToSynchronizable() }
            }
            await reconcileSyncedPins()
            await reconcileSyncedPlaylists()
        } else {
            try await offMain(honorsCancellation: false) {
                for store in stores { try store.stopSynchronizing(deleteCloudCopy: deleteCloudCopy) }
            }
            preference.isEnabled = false
        }
    }

    /// PIN-hashen finns nu lokalt (den anlänt via iCloud Keychain eller migrerats): lås upp varje synkad profil som
    /// väntat på den. Billig; no-op utan synkkoordinator (standardbygget).
    func reconcileSyncedPins() async {
        guard let sync = syncCoordinator else { return }
        let locked = profileStore.allProfiles().map(\.id).filter { sync.profileNeedsPin($0) }
        guard !locked.isEmpty else { return }
        let pins = pins
        let present = (try? await offMain(honorsCancellation: false) {
            locked.filter { (try? pins.hasPin(profileID: $0)) == true }
        }) ?? []
        for id in present { sync.clearPinMissing(id) }
    }

    /// Fjärrspellistor (`fromRemote`) vars inloggning nu finns i Keychain blir användbara: raden läggs i databasen,
    /// `fromRemote` släpps (utan ny tidsstämpel) och importen startas. Rör aldrig andra spellistor. No-op utan
    /// fjärrspellistor, alltså i standardbygget.
    func reconcileSyncedPlaylists() async {
        let remote = playlistMetadata.all().filter(\.fromRemote)
        guard !remote.isEmpty else { return }
        let store = store, credentials = credentials
        let ready: [UUID]
        do {
            ready = try await offMain(honorsCancellation: false) { () throws -> [UUID] in
                let existing = Set(try store.playlists().map(\.id))
                var out: [UUID] = []
                for entry in remote {
                    // Läsfel (t.ex. låst Keychain): försök igen vid nästa tillfälle.
                    guard (try? credentials.load(for: entry.id)) != nil else { continue }
                    if !existing.contains(entry.id) { try store.upsertPlaylist(entry.playlist) }
                    out.append(entry.id)
                }
                return out
            }
        } catch {
            return
        }
        guard !ready.isEmpty else { return }
        playlistMetadata.markResolved(ready)
        await reloadPlaylists()
        for id in ready { startRefresh(id) }
        scheduleMetadata(ready)
        syncCoordinator?.retryPendingOffsets()
    }

    /// Kör avstämningarna i bakgrunden när iCloud Keychain är på (förgrund, efter varje synkapplicering).
    func scheduleKeychainReconcile() {
        guard keychainSyncActive, keychainReconcileTask == nil else { return }
        keychainReconcileTask = Task { [weak self] in
            await self?.reconcileSyncedPins()
            await self?.reconcileSyncedPlaylists()
            self?.keychainReconcileTask = nil
        }
    }
}
