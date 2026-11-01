import Core
import CryptoKit
import Foundation
import Personal
import Security

/// Fel vid inställning av profil-PIN. Fast beskrivning, aldrig själva PIN-koden.
public enum PinError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFormat
    public var description: String { "PIN måste bestå av exakt fyra siffror" }
}

/// Lagrar profil-PIN som saltad SHA-256-hash i Keychain, i en egen service
/// (skild från spellistornas så att städning av spellistor aldrig rör PIN-koder).
/// Standard är lokala poster; synkat läge och migrering fungerar som i `KeychainCredentialStore`.
public final class KeychainProfilePinStore: ProfilePinStore, KeychainSyncMigrating {
    private let service: String
    private let isSynchronizable: @Sendable () -> Bool

    public init(service: String = "se.sjodin.iptv.profilepin", synchronizable: Bool = false) {
        self.service = service
        self.isSynchronizable = { synchronizable }
    }

    /// Läser läget lazy vid varje anrop.
    public init(service: String = "se.sjodin.iptv.profilepin", synchronizableProvider: @escaping @Sendable () -> Bool) {
        self.service = service
        self.isSynchronizable = synchronizableProvider
    }

    private struct Stored: Codable {
        let salt: Data  // base64 i JSON
        let hash: Data
    }

    private static func digest(salt: Data, pin: String) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }

    private static func isValid(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    public func setPin(_ pin: String?, profileID: UUID) throws {
        guard let pin else { return try removePin(profileID: profileID) }
        guard Self.isValid(pin) else { throw PinError.invalidFormat }
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw KeychainError(status: rc) }
        let data = try JSONEncoder().encode(Stored(salt: salt, hash: Self.digest(salt: salt, pin: pin)))
        try KeychainItems.store(service: service, account: profileID.uuidString, data: data,
                                synchronizable: isSynchronizable())
    }

    public func verify(_ pin: String, profileID: UUID) throws -> Bool {
        guard let data = try KeychainItems.load(service: service, account: profileID.uuidString,
                                                synchronizable: isSynchronizable()) else { return false }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw KeychainError(status: errSecDecode)
        }
        let candidate = Self.digest(salt: stored.salt, pin: pin)
        // Konstant tid: ackumulera skillnader över hela digesten.
        guard candidate.count == stored.hash.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, stored.hash) { diff |= a ^ b }
        return diff == 0
    }

    public func removePin(profileID: UUID) throws {
        try KeychainItems.remove(service: service, account: profileID.uuidString, synchronizable: isSynchronizable())
    }

    /// Finns en PIN-hash för profilen (lokal eller, i synkat läge, synkad)? Läser aldrig ut hashen till anroparen.
    public func hasPin(profileID: UUID) throws -> Bool {
        try KeychainItems.load(service: service, account: profileID.uuidString,
                               synchronizable: isSynchronizable()) != nil
    }

    /// Flyttar varje lokal hash till en synkad (skriv, verifiera, ta sedan bort den lokala). Säker att upprepa.
    public func migrateToSynchronizable() throws {
        try KeychainItems.migrateToCloud(service: service)
    }

    /// Skriver en lokal kopia av varje synkad hash (verifierad) och raderar därefter, bara om `deleteCloudCopy`,
    /// den synkade kopian. VARNING: det raderar hashen på ALLA användarens enheter.
    public func stopSynchronizing(deleteCloudCopy: Bool) throws {
        try KeychainItems.stopSyncing(service: service, deleteCloudCopy: deleteCloudCopy)
    }
}
