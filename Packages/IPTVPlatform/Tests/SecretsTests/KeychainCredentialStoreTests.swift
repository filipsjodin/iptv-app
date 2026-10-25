import Core
import Foundation
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
