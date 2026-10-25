import Core
import Foundation
import Library
import Observation
import Providers
import Secrets

@MainActor @Observable
final class AppModel {
    var playlists: [Playlist] = []
    var counts: [UUID: [ContentKind: Int]] = [:]
    var importState: [UUID: ImportPhase] = [:]
    /// Lokaliserat, fast meddelande. Innehåller aldrig server, URL, användarnamn eller underliggande fel.
    var lastError: String?

    let store: LibraryStore
    private let credentials: CredentialStore
    private let http: HTTPClient

    init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient) {
        self.store = store
        self.credentials = credentials
        self.http = http
    }

    static func live() -> AppModel {
        AppModel(store: LibraryStore(db: try! AppDatabase.inMemory()), credentials: KeychainCredentialStore(),
                 http: URLSessionHTTPClient())
    }

    func isImporting(_ id: UUID) -> Bool { false }
    func load() async {}
    func addPlaylist(name: String, secret: PlaylistSecret) async {}
    func refresh(_ id: UUID) async {}
    func refreshAll() async {}
    func remove(_ id: UUID) async {}
}
