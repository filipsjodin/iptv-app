import Core
import Foundation
import Security
import Testing

@testable import Secrets

@Test func keychainRoundTrip() throws {
    let k = KeychainCredentialStore(service: "test.\(UUID())")
    let id = UUID()
    defer { try? k.delete(for: id) }
    let s = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "u", password: "p")
    try k.save(s, for: id)
    #expect(try k.load(for: id) == s)
    let m = PlaylistSecret.m3u(url: URL(string: "http://x/p.m3u")!, epgURL: nil)
    try k.save(m, for: id)  // överskrivning, inget duplicate-fel
    #expect(try k.load(for: id) == m)
    try k.delete(for: id)
    #expect(try k.load(for: id) == nil)
    try k.delete(for: id)  // idempotent
}

@Test func keychainErrorHasNoPayload() {
    #expect(KeychainError(status: -25299).description == "Keychain-fel (OSStatus -25299)")
}

@Test func keychainListsPlaylistIDs() throws {
    let service = "test.\(UUID())"
    let k = KeychainCredentialStore(service: service)
    let a = UUID(), b = UUID()
    defer { try? k.delete(for: a); try? k.delete(for: b) }
    #expect(try k.allPlaylistIDs().isEmpty)
    let s = PlaylistSecret.m3u(url: URL(string: "http://x/p.m3u")!, epgURL: nil)
    try k.save(s, for: a)
    try k.save(s, for: b)
    let junk: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "not-a-uuid",
        kSecValueData as String: Data("x".utf8),
    ]
    #expect(SecItemAdd(junk as CFDictionary, nil) == errSecSuccess)
    defer { SecItemDelete(junk as CFDictionary) }
    #expect(Set(try k.allPlaylistIDs()) == [a, b])
}
