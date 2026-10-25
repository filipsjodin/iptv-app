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
/// Ingen iCloud-synkronisering i denna fas.
public final class KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "se.sjodin.iptv.playlist") {
        self.service = service
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func save(_ secret: PlaylistSecret, for id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        var add = baseQuery(id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw KeychainError(status: status) }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let u = SecItemUpdate(baseQuery(id) as CFDictionary, update as CFDictionary)
        guard u == errSecSuccess else { throw KeychainError(status: u) }
    }

    public func load(for id: UUID) throws -> PlaylistSecret? {
        var q = baseQuery(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(PlaylistSecret.self, from: data)
    }

    public func delete(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Alla sparade spellist-ID:n för tjänsten. Konton som inte är UUID hoppas över.
    public func allPlaylistIDs() throws -> [UUID] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw KeychainError(status: status) }
        return rows.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }
}
