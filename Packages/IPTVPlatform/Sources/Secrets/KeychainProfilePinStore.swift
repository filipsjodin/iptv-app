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
public final class KeychainProfilePinStore: ProfilePinStore {
    private let service: String

    public init(service: String = "se.sjodin.iptv.profilepin") {
        self.service = service
    }

    private struct Stored: Codable {
        let salt: Data  // base64 i JSON
        let hash: Data
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
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
        var add = baseQuery(profileID)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw KeychainError(status: status) }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let u = SecItemUpdate(baseQuery(profileID) as CFDictionary, update as CFDictionary)
        guard u == errSecSuccess else { throw KeychainError(status: u) }
    }

    public func verify(_ pin: String, profileID: UUID) throws -> Bool {
        var q = baseQuery(profileID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        let candidate = Self.digest(salt: stored.salt, pin: pin)
        // Konstant tid: ackumulera skillnader över hela digesten.
        guard candidate.count == stored.hash.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, stored.hash) { diff |= a ^ b }
        return diff == 0
    }

    public func removePin(profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
