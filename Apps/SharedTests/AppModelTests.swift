import Core
import Foundation
import GRDB
import Library
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

/// Spionerande Keychain-ersättare som kan fås att fallera vid sparning.
private final class SpyCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: PlaylistSecret] = [:]
    private(set) var deleted: [UUID] = []
    let failSave: Bool

    init(failSave: Bool = false) { self.failSave = failSave }

    var savedIDs: [UUID] { lock.withLock { Array(secrets.keys) } }

    func save(_ secret: PlaylistSecret, for id: UUID) throws {
        if failSave { throw URLError(.cannotCreateFile) }
        lock.withLock { secrets[id] = secret }
    }
    func load(for id: UUID) throws -> PlaylistSecret? { lock.withLock { secrets[id] } }
    func delete(for id: UUID) throws {
        lock.withLock {
            secrets[id] = nil
            deleted.append(id)
        }
    }
}

private let xtreamSecret = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "u", password: "p")

@MainActor
struct AppModelTests {
    @Test func addPlaylistStoresSecretOnlyInKeychainAndImports() async throws {
        let creds = InMemoryCredentialStore()
        let store = LibraryStore(db: try .inMemory())
        let m = AppModel(store: store, credentials: creds, http: StubHTTPClient(fixtures: standardFixtures))
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        #expect(m.playlists.count == 1)
        try #require(m.playlists.count == 1)
        #expect(try creds.load(for: m.playlists[0].id) != nil)
        guard case .done = m.importState[m.playlists[0].id] else { Issue.record("import ej klar"); return }
        #expect(m.lastError == nil)
        #expect((m.counts[m.playlists[0].id]?[.movie] ?? 0) > 0)
        #expect(m.playlists[0].lastImportedAt != nil)
    }

    @Test func unreachableShowsFriendlyRedactedError() async throws {
        let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                         http: FailingHTTPClient(URLError(.timedOut)))
        await m.addPlaylist(name: "X", secret: .xtream(server: URL(string: "http://80.1.2.3:2095")!,
                                                       username: "u", password: "p"))
        #expect(m.lastError != nil)
        #expect(!(m.lastError ?? "").contains("80.1.2.3"))
        #expect(!(m.lastError ?? "").contains("2095"))
        #expect(m.lastError == UserFacingError.message(for: ProviderError.unreachable))
    }

    @Test func removeDeletesKeychainAndRows() async throws {
        let creds = InMemoryCredentialStore()
        let store = LibraryStore(db: try .inMemory())
        let m = AppModel(store: store, credentials: creds, http: StubHTTPClient(fixtures: standardFixtures))
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        try #require(m.playlists.count == 1)
        let id = m.playlists[0].id
        await m.remove(id)
        #expect(try creds.load(for: id) == nil)
        #expect(try store.playlists().isEmpty)
        #expect(try store.counts(playlistID: id).values.allSatisfy { $0 == 0 })
        #expect(m.playlists.isEmpty)
        #expect(m.importState[id] == nil)
    }

    @Test func keychainFailureDoesNotCreatePlaylist() async throws {
        let store = LibraryStore(db: try .inMemory())
        let m = AppModel(store: store, credentials: SpyCredentialStore(failSave: true),
                         http: StubHTTPClient(fixtures: standardFixtures))
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        #expect(try store.playlists().isEmpty)
        #expect(m.playlists.isEmpty)
        #expect(m.lastError != nil)
    }

    @Test func failedUpsertDeletesSavedSecret() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { try $0.execute(sql: "DROP TABLE playlist") }
        let creds = SpyCredentialStore()
        let m = AppModel(store: LibraryStore(db: db), credentials: creds,
                         http: StubHTTPClient(fixtures: standardFixtures))
        await m.addPlaylist(name: "Min", secret: xtreamSecret)
        #expect(creds.savedIDs.isEmpty)
        #expect(creds.deleted.count == 1)
        #expect(m.lastError == UserFacingError.message(for: ImportError.storageFailed))
    }

    @Test func errorMessagesNeverIncludeDetails() {
        let errors: [Error] = [
            ProviderError.http(503), ProviderError.accountExpired(Date()), ProviderError.unauthorized,
            ImportError.storageFailed, CoreError.missingSecret, URLError(.badURL, userInfo: [
                NSURLErrorFailingURLStringErrorKey: "http://80.1.2.3:2095/get.php?username=u&password=p",
            ]),
        ]
        for e in errors {
            let msg = UserFacingError.message(for: e)
            #expect(!msg.isEmpty)
            #expect(!msg.contains("503"))
            #expect(!msg.contains("80.1.2.3"))
            #expect(!msg.contains("username="))
        }
    }
}

struct PlaylistInputTests {
    @Test func serverWithoutSchemeGetsHTTP() {
        #expect(PlaylistInput.normalizedURL("  example.com:8080 ")?.absoluteString == "http://example.com:8080")
        #expect(PlaylistInput.normalizedURL("https://example.com")?.absoluteString == "https://example.com")
    }

    @Test func rejectsInvalidURLs() {
        #expect(PlaylistInput.normalizedURL("") == nil)
        #expect(PlaylistInput.normalizedURL("   ") == nil)
        #expect(PlaylistInput.normalizedURL("ftp://example.com") == nil)
        #expect(PlaylistInput.normalizedURL("http://") == nil)
    }

    @Test func xtreamRequiresAllFieldsAndTrims() {
        var input = PlaylistInput(kind: .xtream, server: "example.com", username: " user ", password: "")
        #expect(!input.isValid)
        input.password = " secret\n"
        #expect(input.secret == .xtream(server: URL(string: "http://example.com")!, username: "user",
                                        password: "secret"))
    }

    @Test func m3uWithOptionalEPG() {
        var input = PlaylistInput(kind: .m3u, m3uURL: "list.example/get.php")
        #expect(input.secret == .m3u(url: URL(string: "http://list.example/get.php")!, epgURL: nil))
        input.epgURL = "ftp://bad"
        #expect(!input.isValid)
        input.epgURL = "https://epg.example/xmltv"
        #expect(input.secret == .m3u(url: URL(string: "http://list.example/get.php")!,
                                     epgURL: URL(string: "https://epg.example/xmltv")!))
    }

    @Test func emptyNameGetsDefault() {
        #expect(!PlaylistInput(kind: .xtream).trimmedName.isEmpty)
        #expect(PlaylistInput(name: "  Hem ").trimmedName == "Hem")
    }
}
