import Foundation
import Security
import Subtitles

/// Lagrar OpenSubtitles-uppgifterna (en post) som JSON i Keychain, i en egen service skild från spellistornas och
/// PIN-koderna. Ingen iCloud-synkronisering. Fel bär bara statuskoden, aldrig uppgifterna.
public final class KeychainOpenSubtitlesStore: OpenSubtitlesCredentialStore {
    private let service: String
    private let account = "opensubtitles"

    public init(service: String = "se.sjodin.iptv.opensubtitles") {
        self.service = service
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ credentials: OpenSubtitlesCredentials) throws {
        let data: Data
        do { data = try JSONEncoder().encode(credentials) } catch { throw KeychainError(status: errSecParam) }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw KeychainError(status: status) }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let u = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        guard u == errSecSuccess else { throw KeychainError(status: u) }
    }

    public func load() throws -> OpenSubtitlesCredentials? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        // Avkodningsfel kan nämna fält; översätt till ett fast fel utan innehåll.
        do { return try JSONDecoder().decode(OpenSubtitlesCredentials.self, from: data) }
        catch { throw KeychainError(status: errSecDecode) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
