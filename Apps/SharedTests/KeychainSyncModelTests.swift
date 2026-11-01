import Core
import Foundation
import Library
import Personal
import Providers
import ProvidersTestSupport
import Secrets
import Security
import Testing
@testable import IPTVApp

/// Lager som loggar flyttanropen. Inga riktiga Keychain-poster.
private final class RecordingMigratingStore: CredentialStore, KeychainSyncMigrating, @unchecked Sendable {
    // @unchecked Sendable: `calls` och `failure` skyddas av `lock`.
    private let lock = NSLock()
    private var recorded: [String] = []
    private var failure: Bool
    private let inner = InMemoryCredentialStore()

    init(failing: Bool = false) { failure = failing }

    var calls: [String] { lock.withLock { recorded } }
    func stopFailing() { lock.withLock { failure = false } }

    func save(_ secret: PlaylistSecret, for id: UUID) throws { try inner.save(secret, for: id) }
    func load(for id: UUID) throws -> PlaylistSecret? { try inner.load(for: id) }
    func delete(for id: UUID) throws { try inner.delete(for: id) }
    func allPlaylistIDs() throws -> [UUID] { try inner.allPlaylistIDs() }

    func migrateToSynchronizable() throws {
        let fail: Bool = lock.withLock {
            recorded.append("migrate")
            return failure
        }
        if fail { throw KeychainError(status: errSecInteractionNotAllowed) }
    }

    func stopSynchronizing(deleteCloudCopy: Bool) throws {
        lock.withLock { recorded.append("stop(\(deleteCloudCopy))") }
    }
}

@MainActor
struct KeychainSyncModelTests {
    private func makeModel(credentials: CredentialStore = InMemoryCredentialStore(),
                           defaults: UserDefaults = freshDefaults()) throws -> AppModel {
        AppModel(store: LibraryStore(db: try AppDatabase.inMemory()), credentials: credentials,
                 http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
    }

    @Test func defaultBuildNeverEnablesKeychainSync() async throws {
        let defaults = freshDefaults()
        // Även en kvarglömd nyckel ger aldrig synkat läge när bygget saknar synk.
        defaults.set(true, forKey: KeychainSyncPreference.key)
        let model = try makeModel(defaults: defaults)
        #expect(!model.keychainSyncAvailable)
        #expect(!model.keychainSyncActive)
        #expect(!SyncAvailability.isAvailable(infoValue: "NO"))
        #expect(!SyncAvailability.isAvailable(infoValue: nil))
        // Testpaketet saknar SyncEnabled: ingen synk.
        #expect(!SyncAvailability.isAvailable(bundle: Bundle(for: BundleToken.self)))

        let clean = freshDefaults()
        let other = try makeModel(defaults: clean)
        await #expect(throws: KeychainSyncError.unavailable) { try await other.setKeychainSyncEnabled(true) }
        try await other.setKeychainSyncEnabled(false)  // no-op
        #expect(clean.object(forKey: KeychainSyncPreference.key) == nil)
        #expect(other.syncCoordinator == nil)
    }

    @Test func enablingMigratesAndDisablingStopsInSafeOrder() async throws {
        let store = RecordingMigratingStore()
        let defaults = freshDefaults()
        let model = try makeModel(credentials: store, defaults: defaults)
        model.keychainSyncAvailable = true  // som ett synkbygge
        try await model.setKeychainSyncEnabled(true)
        #expect(KeychainSyncPreference(defaults: defaults).isEnabled)
        #expect(model.keychainSyncActive)
        #expect(store.calls == ["migrate"])

        try await model.setKeychainSyncEnabled(false)  // lämnar molnkopian
        #expect(!KeychainSyncPreference(defaults: defaults).isEnabled)
        #expect(store.calls == ["migrate", "stop(false)"])

        try await model.setKeychainSyncEnabled(true)
        try await model.setKeychainSyncEnabled(false, deleteCloudCopy: true)
        #expect(store.calls.last == "stop(true)")
    }

    @Test func failedMigrationKeepsPreferenceOnSoNothingBecomesUnreadable() async throws {
        let store = RecordingMigratingStore(failing: true)
        let defaults = freshDefaults()
        let model = try makeModel(credentials: store, defaults: defaults)
        model.keychainSyncAvailable = true
        await #expect(throws: KeychainError.self) { try await model.setKeychainSyncEnabled(true) }
        // Läget förblir synkat (läsning hittar båda sorterna) och anropet kan göras om.
        #expect(KeychainSyncPreference(defaults: defaults).isEnabled)
        store.stopFailing()
        try await model.setKeychainSyncEnabled(true)
        #expect(store.calls == ["migrate", "migrate"])
    }
}

private final class BundleToken {}
