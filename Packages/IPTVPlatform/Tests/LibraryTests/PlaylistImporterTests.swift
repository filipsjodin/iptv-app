import Core
import Foundation
import Providers
import ProvidersTestSupport
import Testing

@testable import Library

private let playlistUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

private func fixtureImporter(
    xtream fixtures: [String: String]? = nil,
    http: HTTPClient? = nil,
    secret: PlaylistSecret? = nil,
    preloadedMovies: Int = 0
) throws -> (PlaylistImporter, LibraryStore, UUID) {
    let store = try LibraryStore(db: .inMemory())
    try store.upsertPlaylist(Playlist(id: playlistUUID, name: "T", kind: .xtream, createdAt: Date(timeIntervalSince1970: 1)))
    if preloadedMovies > 0 {
        let movies = (0..<preloadedMovies).map {
            Movie(providerID: "p\($0)", title: "Pre \($0)",
                  locator: .xtream(kind: .movie, streamID: "p\($0)", container: "mp4"))
        }
        try store.replaceCatalog(ProviderCatalog(movies: movies), playlistID: playlistUUID, now: Date(timeIntervalSince1970: 10))
    }
    let creds = InMemoryCredentialStore()
    try creds.save(secret ?? .xtream(server: URL(string: "http://example.invalid")!, username: "u", password: "p"),
                   for: playlistUUID)
    let client: HTTPClient = http ?? StubHTTPClient(fixtures: fixtures ?? standardFixtures)
    return (PlaylistImporter(store: store, credentials: creds, http: client), store, playlistUUID)
}

private struct FixedHTTP: HTTPClient {
    let body: Data
    let code: Int
    func get(_ url: URL) async throws -> (Data, Int) { (body, code) }
}

@Test func importEmitsPhasesInOrderAndStores() async throws {
    let (importer, store, id) = try fixtureImporter(xtream: standardFixtures)
    var phases: [ImportPhase] = []
    for try await ph in importer.run(playlistID: id) { phases.append(ph) }
    #expect(phases.first == .connecting)
    guard case .done(let counts) = phases.last else { Issue.record("no done"); return }
    #expect(counts[.movie] == 5)
    #expect(try store.counts(playlistID: id)[.movie] == 5)
    let order = phases.dropLast().map { String(describing: $0) }
    #expect(order == ["connecting", "downloading", "parsing", "saving"])
    #expect(try store.playlists().first?.lastImportedAt != nil)
}

@Test func missingSecretFailsCleanly() async throws {
    let (importer, _, _) = try fixtureImporter(xtream: standardFixtures)
    await #expect(throws: CoreError.missingSecret) { for try await _ in importer.run(playlistID: UUID()) {} }
}

@Test func unknownPlaylistFails() async throws {
    let (_, store, _) = try fixtureImporter(xtream: standardFixtures)
    let other = UUID()
    let creds = InMemoryCredentialStore()
    try creds.save(.m3u(url: URL(string: "http://x/p.m3u")!, epgURL: nil), for: other)
    let importer = PlaylistImporter(store: store, credentials: creds, http: FixedHTTP(body: Data(), code: 200))
    await #expect(throws: ImportError.unknownPlaylist) { for try await _ in importer.run(playlistID: other) {} }
}

@Test func unreachableKeepsPreviousCatalog() async throws {
    let (importer, store, id) = try fixtureImporter(http: FailingHTTPClient(URLError(.timedOut)), preloadedMovies: 3)
    await #expect(throws: ProviderError.unreachable) { for try await _ in importer.run(playlistID: id) {} }
    #expect(try store.counts(playlistID: id)[.movie] == 3)
    #expect(try store.playlists().first?.lastImportedAt == Date(timeIntervalSince1970: 10))
}

@Test func m3uImportStoresAndMapsHTTPErrors() async throws {
    let text = "#EXTM3U\n#EXTINF:-1 group-title=\"News\",Chan 1\nhttp://s.example/live/1.ts\n"
    let secret = PlaylistSecret.m3u(url: URL(string: "http://s.example/p.m3u")!, epgURL: nil)
    let (ok, store, id) = try fixtureImporter(http: FixedHTTP(body: Data(text.utf8), code: 200), secret: secret)
    var last: ImportPhase?
    for try await ph in ok.run(playlistID: id) { last = ph }
    guard case .done(let counts) = last else { Issue.record("no done"); return }
    #expect(counts[.live] == 1)
    #expect(try store.counts(playlistID: id)[.live] == 1)

    let (denied, _, id2) = try fixtureImporter(http: FixedHTTP(body: Data(), code: 403), secret: secret)
    await #expect(throws: ProviderError.unauthorized) { for try await _ in denied.run(playlistID: id2) {} }
    let (broken, _, id3) = try fixtureImporter(http: FixedHTTP(body: Data(), code: 500), secret: secret)
    await #expect(throws: ProviderError.http(500)) { for try await _ in broken.run(playlistID: id3) {} }
}

private struct ThrowingCredentials: CredentialStore {
    func save(_ secret: PlaylistSecret, for id: UUID) throws {}
    func load(for id: UUID) throws -> PlaylistSecret? { throw URLError(.cannotOpenFile) }
    func delete(for id: UUID) throws {}
    func allPlaylistIDs() throws -> [UUID] { [] }
}

@Test func importerStoresXtreamAccountInfo() async throws {
    let (importer, store, id) = try fixtureImporter(xtream: standardFixtures)
    for try await _ in importer.run(playlistID: id) {}
    #expect(try store.accountInfo(playlistID: id)
            == PlaylistAccountInfo(maxConnections: 2, expiresAt: Date(timeIntervalSince1970: 1_798_761_600),
                                   status: "Active"))
}

private struct SlowHTTP: HTTPClient {
    func get(_ url: URL) async throws -> (Data, Int) {
        try await Task.sleep(for: .seconds(30))
        return (Data("#EXTM3U\n#EXTINF:-1,A\nhttp://s.example/live/1.ts\n".utf8), 200)
    }
}

@Test func unreadableSecretIsLocalError() async throws {
    let (_, store, id) = try fixtureImporter(xtream: standardFixtures)
    let importer = PlaylistImporter(store: store, credentials: ThrowingCredentials(),
                                    http: FixedHTTP(body: Data(), code: 200))
    await #expect(throws: ImportError.secretUnreadable) { for try await _ in importer.run(playlistID: id) {} }
}

@Test func storageFailureIsLocalError() async throws {
    // Spellistan raderas under nedladdningen: FK-brott i replaceCatalog ger ett databasfel.
    final class Holder: @unchecked Sendable { var store: LibraryStore? }
    struct DeletingHTTP: HTTPClient {
        let holder: Holder
        func get(_ url: URL) async throws -> (Data, Int) {
            try holder.store?.deletePlaylist(playlistUUID)
            return try await StubHTTPClient(fixtures: standardFixtures).get(url)
        }
    }
    let holder = Holder()
    let (importer, store, id) = try fixtureImporter(http: DeletingHTTP(holder: holder))
    holder.store = store
    await #expect(throws: ImportError.storageFailed) { for try await _ in importer.run(playlistID: id) {} }
}

@Test func cancellationDuringDownloadWritesNothing() async throws {
    let secret = PlaylistSecret.m3u(url: URL(string: "http://s.example/p.m3u")!, epgURL: nil)
    let (importer, store, id) = try fixtureImporter(http: SlowHTTP(), secret: secret, preloadedMovies: 3)
    let consumer = Task { () -> [ImportPhase] in
        var phases: [ImportPhase] = []
        do { for try await ph in importer.run(playlistID: id) { phases.append(ph) } } catch {}
        return phases
    }
    try await Task.sleep(for: .milliseconds(300))
    consumer.cancel()
    let phases = await consumer.value  // returnerar bara om strömmen avslutades
    #expect(!phases.contains(where: { if case .done = $0 { true } else { false } }))
    #expect(try store.counts(playlistID: id)[.movie] == 3)
    #expect(try store.counts(playlistID: id)[.live] == 0)
}

// MARK: - Skydd mot att biblioteket töms vid uppdatering

private let m3uSecret = PlaylistSecret.m3u(url: URL(string: "http://s.example/p.m3u")!, epgURL: nil)

@Test(arguments: [
    "<!DOCTYPE html><html><body>Account expired</body></html>",
    "",
    "#EXTM3U\n",
    "Your subscription has expired",
])
func m3uWithoutEntriesFailsAndKeepsCatalog(body: String) async throws {
    let (importer, store, id) = try fixtureImporter(http: FixedHTTP(body: Data(body.utf8), code: 200),
                                                    secret: m3uSecret, preloadedMovies: 3)
    await #expect(throws: ProviderError.invalidResponse) { for try await _ in importer.run(playlistID: id) {} }
    #expect(try store.counts(playlistID: id)[.movie] == 3)
    #expect(try store.playlists().first?.lastImportedAt == Date(timeIntervalSince1970: 10))
}

private let emptyXtreamFixtures: [String: String] = [
    "": "xtream_user_info.json",
    "get_vod_categories": "xtream_empty_list.json",
    "get_series_categories": "xtream_empty_list.json",
    "get_live_categories": "xtream_empty_list.json",
    "get_vod_streams": "xtream_empty_list.json",
    "get_series": "xtream_empty_list.json",
    "get_live_streams": "xtream_empty_list.json",
]

@Test func emptyXtreamCatalogFailsWhenLibraryHasItems() async throws {
    let (importer, store, id) = try fixtureImporter(xtream: emptyXtreamFixtures, preloadedMovies: 3)
    await #expect(throws: ProviderError.invalidResponse) { for try await _ in importer.run(playlistID: id) {} }
    #expect(try store.counts(playlistID: id)[.movie] == 3)
    #expect(try store.playlists().first?.lastImportedAt == Date(timeIntervalSince1970: 10))
}

@Test func emptyFirstImportIsAllowed() async throws {
    let (importer, store, id) = try fixtureImporter(xtream: emptyXtreamFixtures)
    var last: ImportPhase?
    for try await ph in importer.run(playlistID: id) { last = ph }
    guard case .done(let counts) = last else { Issue.record("no done"); return }
    #expect(counts.values.reduce(0, +) == 0)
    #expect(try store.counts(playlistID: id).values.reduce(0, +) == 0)
}
