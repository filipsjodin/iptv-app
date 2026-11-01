import Core
import Foundation
import Security

/// Fel från Keychain. Bär bara statuskoden, aldrig hemligheten.
public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String { "Keychain-fel (OSStatus \(status))" }
}

/// Lagrar `PlaylistSecret` som JSON i Keychain (generic password, en post per spellista).
/// Standard är lokala poster, exakt som förut. Med synkat läge (valfritt, av som standard) skrivs posterna som
/// iCloud-Keychain-synkroniserbara och läsning hittar både lokala och synkade poster. Aldrig `ThisDeviceOnly`.
public final class KeychainCredentialStore: CredentialStore, KeychainSyncMigrating {
    private let service: String
    private let isSynchronizable: @Sendable () -> Bool

    public init(service: String = "se.sjodin.iptv.playlist", synchronizable: Bool = false) {
        self.service = service
        self.isSynchronizable = { synchronizable }
    }

    /// Läser läget lazy vid varje anrop, så att en inställningsändring gäller direkt utan att lagret byts ut.
    public init(service: String = "se.sjodin.iptv.playlist", synchronizableProvider: @escaping @Sendable () -> Bool) {
        self.service = service
        self.isSynchronizable = synchronizableProvider
    }

    public func save(_ secret: PlaylistSecret, for id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        try KeychainItems.store(service: service, account: id.uuidString, data: data,
                                synchronizable: isSynchronizable())
    }

    public func load(for id: UUID) throws -> PlaylistSecret? {
        guard let data = try KeychainItems.load(service: service, account: id.uuidString,
                                                synchronizable: isSynchronizable()) else { return nil }
        // Avkodningsfel kan citera innehållet; släpp bara statuskoden vidare.
        guard let secret = try? JSONDecoder().decode(PlaylistSecret.self, from: data) else {
            throw KeychainError(status: errSecDecode)
        }
        return secret
    }

    public func delete(for id: UUID) throws {
        try KeychainItems.remove(service: service, account: id.uuidString, synchronizable: isSynchronizable())
    }

    /// Alla sparade spellist-ID:n för tjänsten (lokala och, i synkat läge, synkade). Konton som inte är UUID
    /// hoppas över.
    public func allPlaylistIDs() throws -> [UUID] {
        try KeychainItems.list(service: service, synchronizable: isSynchronizable())
            .compactMap(UUID.init(uuidString:))
    }

    /// Flyttar varje lokal post till en synkad (skriv, verifiera, ta sedan bort den lokala). Säker att upprepa.
    public func migrateToSynchronizable() throws {
        try KeychainItems.migrateToCloud(service: service)
    }

    /// Skriver en lokal kopia av varje synkad post (verifierad) och raderar därefter, bara om `deleteCloudCopy`,
    /// den synkade kopian. VARNING: att radera en synkroniserbar post raderar den på ALLA användarens enheter.
    public func stopSynchronizing(deleteCloudCopy: Bool) throws {
        try KeychainItems.stopSyncing(service: service, deleteCloudCopy: deleteCloudCopy)
    }
}
