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
    private var importTasks: [UUID: Task<Void, Never>] = [:]

    init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient) {
        self.store = store
        self.credentials = credentials
        self.http = http
    }

    /// Produktionsuppsättning: databas på disk, Keychain och `URLSessionHTTPClient()` med paketets
    /// standardvärden (30 s per förfrågan, 600 s per resurs – räcker för stora kataloger).
    static func live() -> AppModel {
        let http = URLSessionHTTPClient()
        let credentials = KeychainCredentialStore()
        do {
            return AppModel(store: LibraryStore(db: try LibraryLocation.open()), credentials: credentials, http: http)
        } catch {
            // Sista utväg: en tillfällig databas så att appen ändå startar.
            // swiftlint:disable:next force_try
            let model = AppModel(store: LibraryStore(db: try! AppDatabase.inMemory()), credentials: credentials,
                                 http: http)
            model.lastError = String(localized: "The library could not be opened on this device.")
            return model
        }
    }

    func isImporting(_ id: UUID) -> Bool { importTasks[id] != nil }

    func load() async {
        await reloadPlaylists()
    }

    /// Ordning: hemligheten i Keychain → raden i databasen → import. Misslyckas raden tas hemligheten bort igen.
    func addPlaylist(name: String, secret: PlaylistSecret) async {
        let kind: PlaylistSourceKind = switch secret {
        case .xtream: .xtream
        case .m3u: .m3u
        }
        let playlist = Playlist(name: name, kind: kind)
        let id = playlist.id
        let store = store, credentials = credentials

        do {
            try await offMain { try credentials.save(secret, for: id) }
        } catch {
            report(error)
            return
        }
        do {
            try await offMain { try store.upsertPlaylist(playlist) }
        } catch {
            try? await offMain { try credentials.delete(for: id) }
            report(ImportError.storageFailed)
            return
        }
        await reloadPlaylists()
        await refresh(id)
    }

    /// Kör (om)import och väntar tills den är klar. Pågår redan en import för spellistan väntar vi in den.
    func refresh(_ id: UUID) async {
        if let running = importTasks[id] {
            await running.value
            return
        }
        let importer = PlaylistImporter(store: store, credentials: credentials, http: http)
        let task = Task { [weak self] in
            do {
                for try await phase in importer.run(playlistID: id) {
                    self?.importState[id] = phase
                }
            } catch is CancellationError {
                self?.importState[id] = nil
            } catch {
                self?.importState[id] = nil
                self?.report(error)
            }
        }
        importTasks[id] = task
        await task.value
        importTasks[id] = nil
        await reloadPlaylists()
    }

    func refreshAll() async {
        let ids = playlists.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// Avbryter pågående import och tar bort Keychain-posten och alla databasrader. Båda försöks även om den
    /// ena misslyckas.
    func remove(_ id: UUID) async {
        if let running = importTasks[id] {
            running.cancel()
            await running.value
        }
        let store = store, credentials = credentials
        var failure: Error?
        do { try await offMain { try credentials.delete(for: id) } } catch { failure = error }
        do { try await offMain { try store.deletePlaylist(id) } } catch { failure = failure ?? ImportError.storageFailed }
        importState[id] = nil
        counts[id] = nil
        if let failure { report(failure) }
        await reloadPlaylists()
    }

    private func reloadPlaylists() async {
        let store = store
        do {
            let (lists, counts) = try await offMain {
                let lists = try store.playlists()
                var counts: [UUID: [ContentKind: Int]] = [:]
                for p in lists { counts[p.id] = try store.counts(playlistID: p.id) }
                return (lists, counts)
            }
            playlists = lists
            self.counts = counts
        } catch {
            report(ImportError.storageFailed)
        }
    }

    private func report(_ error: Error) {
        lastError = UserFacingError.message(for: error)
    }
}
