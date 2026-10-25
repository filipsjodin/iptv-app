import Foundation
import Testing
@testable import Core

@Test func inMemoryStoreRoundTrip() throws {
    let store = InMemoryCredentialStore(); let id = UUID()
    let s = PlaylistSecret.m3u(url: URL(string: "http://h/get.php?username=u&password=p")!, epgURL: nil)
    try store.save(s, for: id); #expect(try store.load(for: id) == s)
    try store.delete(for: id); #expect(try store.load(for: id) == nil)
}
