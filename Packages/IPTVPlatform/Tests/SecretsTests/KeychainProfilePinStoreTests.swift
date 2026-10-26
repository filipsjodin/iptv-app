import Core
import Foundation
import Security
import Testing

@testable import Secrets

@Test func pinRoundTripAndWrongPin() throws {
    let k = KeychainProfilePinStore(service: "test.pin.\(UUID())")
    let id = UUID()
    defer { try? k.removePin(profileID: id) }
    #expect(try k.verify("1234", profileID: id) == false)  // ingen PIN → false
    try k.setPin("1234", profileID: id)
    #expect(try k.verify("1234", profileID: id))
    #expect(try k.verify("4321", profileID: id) == false)
    try k.setPin("9999", profileID: id)  // överskrivning
    #expect(try k.verify("9999", profileID: id))
    #expect(try k.verify("1234", profileID: id) == false)
    try k.setPin(nil, profileID: id)
    #expect(try k.verify("9999", profileID: id) == false)
    try k.removePin(profileID: id)  // idempotent
}

@Test func pinRejectsInvalidFormat() throws {
    let k = KeychainProfilePinStore(service: "test.pin.\(UUID())")
    let id = UUID()
    for bad in ["", "123", "12345", "12a4", "١٢٣٤", "12 4"] {
        #expect(throws: PinError.invalidFormat) { try k.setPin(bad, profileID: id) }
    }
}

@Test func pinStoredHashedNotPlain() throws {
    let service = "test.pin.\(UUID())"
    let k = KeychainProfilePinStore(service: service)
    let id = UUID()
    defer { try? k.removePin(profileID: id) }
    try k.setPin("1234", profileID: id)
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
    let data = try #require(out as? Data)
    #expect(String(decoding: data, as: UTF8.self).contains("1234") == false)
    #expect(data.range(of: Data("1234".utf8)) == nil)
}

@Test func playlistSweepDoesNotTouchPins() throws {
    let id = UUID()
    let pins = KeychainProfilePinStore(service: "test.pin.\(UUID())")
    defer { try? pins.removePin(profileID: id) }
    try pins.setPin("1234", profileID: id)
    let playlists = KeychainCredentialStore(service: "test.playlist.\(UUID())")
    #expect(try playlists.allPlaylistIDs().contains(id) == false)
}

@Test func profileWithoutPinIsNoOp() throws {
    let k = KeychainProfilePinStore(service: "test.pin.\(UUID())")
    let id = UUID()
    try k.removePin(profileID: id)  // ingen post → no-op
    try k.setPin(nil, profileID: id)  // ingen post → no-op
    #expect(try k.verify("1234", profileID: id) == false)
}
