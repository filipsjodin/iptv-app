import Foundation
import Security
import Subtitles
import Testing

@testable import Secrets

@Test func openSubtitlesCredentialsRoundTripAndClear() throws {
    let k = KeychainOpenSubtitlesStore(service: "test.os.\(UUID())")
    defer { try? k.clear() }
    #expect(try k.load() == nil)
    try k.save(OpenSubtitlesCredentials(username: "anna", password: "hemlig1"))
    #expect(try k.load() == OpenSubtitlesCredentials(username: "anna", password: "hemlig1"))
    try k.save(OpenSubtitlesCredentials(username: "bo", password: "hemlig2"))  // överskrivning
    #expect(try k.load() == OpenSubtitlesCredentials(username: "bo", password: "hemlig2"))
    try k.clear()
    #expect(try k.load() == nil)
    try k.clear()  // idempotent
}

@Test func openSubtitlesStoreUsesSeparateService() throws {
    let a = KeychainOpenSubtitlesStore(service: "test.os.\(UUID())")
    let b = KeychainOpenSubtitlesStore(service: "test.os.\(UUID())")
    defer { try? a.clear(); try? b.clear() }
    try a.save(OpenSubtitlesCredentials(username: "u", password: "p"))
    #expect(try b.load() == nil)
    let playlists = KeychainCredentialStore(service: "test.playlist.\(UUID())")
    #expect(try playlists.allPlaylistIDs().isEmpty)
}
