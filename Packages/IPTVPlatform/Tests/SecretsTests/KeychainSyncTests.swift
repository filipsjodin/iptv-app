import Core
import Foundation
import Security
import Testing

@testable import Secrets

// Synkroniserbara Keychain-poster kräver iCloud Keychain-stöd (och ibland entitlements). Simulatorn och
// testvärdar utan det avvisar dem (t.ex. errSecMissingEntitlement). Därför provas det en gång vid körning och
// testerna som behöver det hoppas över (`.enabled(if:)`) när det saknas; de verifieras då på enhet. Testerna
// som inte behöver synkade poster körs alltid.

/// Går det att skriva och läsa tillbaka en synkroniserbar post i den här miljön?
private let keychainSyncSupported: Bool = {
    let service = "test.syncprobe.\(UUID())"
    defer { wipe(service) }
    do { try KeychainItems.write(service: service, account: "probe", data: Data([1]), scope: .cloud) } catch {
        return false
    }
    let back = try? KeychainItems.data(service: service, account: "probe", scope: .cloud)
    return back != nil
}()

private func wipe(_ service: String) {
    SecItemDelete(KeychainItems.query(service: service, account: nil, scope: .any) as CFDictionary)
}

private func secret(for id: UUID) -> PlaylistSecret {
    .xtream(server: URL(string: "http://h.example:1")!, username: "u", password: "pw-\(id.uuidString)")
}

private func credentials(_ service: String, sync: Bool) -> KeychainCredentialStore {
    KeychainCredentialStore(service: service, synchronizable: sync)
}

/// Rå fråga: finns en post i exakt det omfånget?
private func rawStatus(service: String, account: String, scope: KeychainScope) -> OSStatus {
    var q = KeychainItems.query(service: service, account: account, scope: scope)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out)
}

private final class DoneFlag: @unchecked Sendable {
    // @unchecked Sendable: `value` skyddas av `lock`.
    private let lock = NSLock()
    private var value = false
    var isDone: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}

// MARK: - Alltid körda

@Test func defaultModeQueriesUnchanged() throws {
    // Lokala frågor har exakt de gamla nycklarna och inget synkattribut.
    let q = KeychainItems.query(service: "s", account: "a", scope: .local)
    #expect(Set(q.keys) == [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])

    // En post skriven av standardlagret hittas av den gamla råa frågan, och det är en icke-synkad post.
    let service = "test.default.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let store = KeychainCredentialStore(service: service)
    try store.save(secret(for: id), for: id)
    let legacy: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    #expect(SecItemCopyMatching(legacy as CFDictionary, &out) == errSecSuccess)
    let row = try #require(out as? [String: Any])
    let flag = row[kSecAttrSynchronizable as String] as? Bool ?? false
    #expect(flag == false)
}

@Test func errorsNeverContainSecret() throws {
    let password = "testpassword"
    let id = UUID()
    let service = "test.errors.\(UUID())"
    defer { wipe(service) }
    // Statusfel.
    let err = KeychainError(status: errSecMissingEntitlement)
    for text in [err.description, "\(err)", String(describing: err), String(reflecting: err)] {
        #expect(!text.contains(password))
    }
    // Skadad post vars innehåll liknar en hemlighet: avkodningsfelet får inte citera den.
    let junk: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecValueData as String: Data(password.utf8),
    ]
    #expect(SecItemAdd(junk as CFDictionary, nil) == errSecSuccess)
    let store = KeychainCredentialStore(service: service)
    do {
        _ = try store.load(for: id)
        Issue.record("Skadad post ska ge fel")
    } catch {
        for text in [error.localizedDescription, "\(error)", String(describing: error), String(reflecting: error)] {
            #expect(!text.contains(password))
            #expect(!text.contains("testpass"))
        }
        #expect(error as? KeychainError != nil)
    }
    // Hemligheten själv skriver aldrig ut lösenordet.
    let s = PlaylistSecret.xtream(server: URL(string: "http://h")!, username: "u", password: password)
    for text in ["\(s)", String(describing: s), String(reflecting: s), "\(Mirror(reflecting: s).children.count)"] {
        #expect(!text.contains(password))
    }
}

@Test func pinHashSyncsOnlyWhenEnabled() throws {
    let service = "test.pinsync.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    // Av (standard): en lokal, icke-synkroniserbar post.
    let off = KeychainProfilePinStore(service: service)
    try off.setPin("1234", profileID: id)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) == errSecSuccess)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) != errSecSuccess)
    #expect(try off.verify("1234", profileID: id))
    #expect(try off.hasPin(profileID: id))
    // På: en synkroniserbar post (bara där miljön stöder det).
    guard keychainSyncSupported else { return }
    let other = UUID()
    let on = KeychainProfilePinStore(service: service, synchronizable: true)
    try on.setPin("4321", profileID: other)
    #expect(rawStatus(service: service, account: other.uuidString, scope: .cloud) == errSecSuccess)
    #expect(try on.verify("4321", profileID: other))
}

@Test func defaultBuildNeverEnablesKeychainSync() throws {
    let suite = "test.kcpref.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(KeychainSyncPreference(defaults: defaults).isEnabled == false)
    defaults.set(true, forKey: KeychainSyncPreference.key)
    // Bygget har ingen synk: även en satt nyckel ger aldrig synkat läge.
    #expect(KeychainSyncPreference.provider(defaults: defaults, available: false)() == false)
    #expect(KeychainSyncPreference.provider(defaults: defaults, available: true)() == true)
    defaults.set(false, forKey: KeychainSyncPreference.key)
    #expect(KeychainSyncPreference.provider(defaults: defaults, available: true)() == false)
}

@Test func providerIsReadLazilyAndDefaultStoreNeverTouchesCloud() throws {
    let service = "test.lazy.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    // Provider som alltid är falsk: poster skrivs lokalt.
    let store = KeychainCredentialStore(service: service, synchronizableProvider: { false })
    try store.save(secret(for: id), for: id)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) == errSecSuccess)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) != errSecSuccess)
}

// MARK: - Kräver synkroniserbara poster

@Test(.enabled(if: keychainSyncSupported))
func synchronizableItemRoundTrips() throws {
    let service = "test.syncrt.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let store = credentials(service, sync: true)
    try store.save(secret(for: id), for: id)
    #expect(try store.load(for: id) == secret(for: id))
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) == errSecSuccess)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) != errSecSuccess)
    let updated = PlaylistSecret.m3u(url: URL(string: "http://x/p.m3u")!, epgURL: nil)
    try store.save(updated, for: id)  // överskrivning, inget duplicate-fel
    #expect(try store.load(for: id) == updated)
    try store.delete(for: id)
    #expect(try store.load(for: id) == nil)
    try store.delete(for: id)  // idempotent
}

@Test(.enabled(if: keychainSyncSupported))
func readFindsBothLocalAndSyncedItems() throws {
    let service = "test.syncboth.\(UUID())"
    defer { wipe(service) }
    let localID = UUID(), cloudID = UUID()
    try credentials(service, sync: false).save(secret(for: localID), for: localID)
    try credentials(service, sync: true).save(secret(for: cloudID), for: cloudID)
    let reader = credentials(service, sync: true)
    #expect(try reader.load(for: localID) == secret(for: localID))
    #expect(try reader.load(for: cloudID) == secret(for: cloudID))
    #expect(Set(try reader.allPlaylistIDs()) == [localID, cloudID])
    // Standardläget ser bara den lokala.
    let plain = credentials(service, sync: false)
    #expect(try plain.load(for: localID) == secret(for: localID))
    #expect(try plain.load(for: cloudID) == nil)
    #expect(Set(try plain.allPlaylistIDs()) == [localID])
}

@Test(.enabled(if: keychainSyncSupported))
func migrationKeepsSecretReadableThroughout() async throws {
    let service = "test.syncmig.\(UUID())"
    defer { wipe(service) }
    let ids = (0..<8).map { _ in UUID() }
    let local = credentials(service, sync: false)
    for id in ids { try local.save(secret(for: id), for: id) }
    let reader = credentials(service, sync: true)
    let done = DoneFlag()
    let migrator = Task.detached {
        defer { done.finish() }
        try local.migrateToSynchronizable()
    }
    var misses = 0
    var reads = 0
    repeat {
        for id in ids {
            reads += 1
            if try reader.load(for: id) != secret(for: id) { misses += 1 }
        }
    } while !done.isDone
    try await migrator.value
    #expect(reads >= ids.count)
    #expect(misses == 0)  // aldrig ett tomt mellanläge
    for id in ids {
        #expect(try reader.load(for: id) == secret(for: id))
        #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) == errSecSuccess)
        #expect(rawStatus(service: service, account: id.uuidString, scope: .local) != errSecSuccess)
    }
}

@Test(.enabled(if: keychainSyncSupported))
func migrationIdempotent() throws {
    let service = "test.syncidem.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let local = credentials(service, sync: false)
    try local.save(secret(for: id), for: id)
    try local.migrateToSynchronizable()
    try local.migrateToSynchronizable()  // igen: ingen förändring, inget fel
    let reader = credentials(service, sync: true)
    #expect(try reader.load(for: id) == secret(for: id))
    #expect(try reader.allPlaylistIDs() == [id])
    // Tom tjänst: no-op.
    try KeychainCredentialStore(service: "test.syncempty.\(UUID())").migrateToSynchronizable()
}

@Test(.enabled(if: keychainSyncSupported))
func duplicateItemHandled() throws {
    let service = "test.syncdup.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let first = secret(for: id)
    let newer = PlaylistSecret.m3u(url: URL(string: "http://x/new.m3u")!, epgURL: nil)
    // Samma konto som både lokal och synkad post är olika poster.
    try credentials(service, sync: false).save(first, for: id)
    try KeychainItems.write(service: service, account: id.uuidString,
                            data: try JSONEncoder().encode(newer), scope: .cloud)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) == errSecSuccess)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) == errSecSuccess)
    // Läsning i synkat läge föredrar den synkade kopian och listan har kontot en gång.
    let reader = credentials(service, sync: true)
    #expect(try reader.load(for: id) == newer)
    #expect(try reader.allPlaylistIDs() == [id])
    // Migrering med båda närvarande kastar inte och lämnar en läsbar synkad kopia.
    try credentials(service, sync: false).migrateToSynchronizable()
    #expect(try reader.load(for: id) != nil)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) != errSecSuccess)
    // Upprepade sparningar i synkat läge ger inget duplicate-fel.
    try reader.save(first, for: id)
    try reader.save(newer, for: id)
    #expect(try reader.load(for: id) == newer)
}

@Test(.enabled(if: keychainSyncSupported))
func stopSyncingWithoutDeleteKeepsCloudCopy() throws {
    let service = "test.syncstop.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let store = credentials(service, sync: true)
    try store.save(secret(for: id), for: id)
    try store.stopSynchronizing(deleteCloudCopy: false)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) == errSecSuccess)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .local) == errSecSuccess)
    // Standardläget läser nu den lokala kopian.
    #expect(try credentials(service, sync: false).load(for: id) == secret(for: id))
    try store.stopSynchronizing(deleteCloudCopy: false)  // idempotent
}

/// "Both" i brieffens namn: efter avstängning med radering finns inget kvar i molnet; den lokala kopian (som
/// skrevs först) är det som finns kvar, så inloggningen går aldrig förlorad på den här enheten.
@Test(.enabled(if: keychainSyncSupported))
func stopSyncingWithDeleteRemovesBoth() throws {
    let service = "test.syncstopdel.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let store = credentials(service, sync: true)
    try store.save(secret(for: id), for: id)
    try store.stopSynchronizing(deleteCloudCopy: true)
    #expect(rawStatus(service: service, account: id.uuidString, scope: .cloud) != errSecSuccess)
    #expect(try credentials(service, sync: false).load(for: id) == secret(for: id))
    try store.stopSynchronizing(deleteCloudCopy: true)  // idempotent
}

@Test(.enabled(if: keychainSyncSupported))
func pinMigrationAndStopKeepVerifyWorking() throws {
    let service = "test.pinmig.\(UUID())"
    defer { wipe(service) }
    let id = UUID()
    let plain = KeychainProfilePinStore(service: service)
    try plain.setPin("2468", profileID: id)
    try plain.migrateToSynchronizable()
    let synced = KeychainProfilePinStore(service: service, synchronizable: true)
    #expect(try synced.verify("2468", profileID: id))
    try synced.stopSynchronizing(deleteCloudCopy: false)
    #expect(try plain.verify("2468", profileID: id))
    #expect(try plain.hasPin(profileID: id))
}
